#!/bin/bash
# First-boot provisioning: LVM on the two attached Lightsail disks, Podman,
# and a Ghost CMS + MySQL compose stack (podman-compose, rootful).

# Lightsail prepends its own lines to launch scripts and executes them with
# /bin/sh (dash), so the shebang above is ignored. Re-exec under bash before
# using any bash-only feature (set -o pipefail would kill dash immediately).
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

set -euxo pipefail
exec > /var/log/ghost-provision.log 2>&1

MYSQL_DISK="__MYSQL_DISK_PATH__"
CONTENT_DISK="__CONTENT_DISK_PATH__"
JOURNAL_DOMAIN="__JOURNAL_DOMAIN__"
ACME_EMAIL="__ACME_EMAIL__"
APEX_REDIRECT_DOMAIN="__APEX_REDIRECT_DOMAIN__"   # non-empty in prod only
MYSQL_MOUNT=/srv/ghost/mysql-data
CONTENT_MOUNT=/srv/ghost/content
APP_DIR=/srv/ghost
CONFIG_REPO=https://github.com/geekdotdev/web_infrastructure.git
GHOST_CONFIG_DIR=/etc/ghost
# Private per-env config bucket. Created shortly AFTER this instance (the
# access grant needs the instance to exist), so anything pulling from it at
# first boot must retry. Persisted to /etc/environment for later tooling.
DEPLOYMENT_BUCKET="__DEPLOYMENT_BUCKET__"

export DEBIAN_FRONTEND=noninteractive
# Fresh Ubuntu boots run unattended-upgrades, which holds the dpkg lock for
# minutes; make every apt call wait for it instead of failing (exit 100).
APT="apt-get -o DPkg::Lock::Timeout=600"
$APT update -y
$APT install -y lvm2 ca-certificates curl git unzip

# AWS CLI: no apt package on Ubuntu 24.04 — use the official v2 installer.
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
export PATH=/usr/local/bin:$PATH

USED_DISKS=""

# resolve_disk <preferred-path>: echoes a usable block device. Falls back to
# scanning nvme devices (Nitro naming) that are unpartitioned, carry no
# FS/PV signature, and haven't been claimed by an earlier call.
resolve_disk() {
  local preferred=$1 dev cand
  for i in $(seq 1 60); do
    if [ -b "$preferred" ]; then echo "$preferred"; return 0; fi
    for cand in $(lsblk -dno NAME 2>/dev/null | grep '^nvme' || true); do
      dev="/dev/$cand"
      [ "$dev" = "/dev/nvme0n1" ] && continue                    # root disk
      echo "$USED_DISKS" | grep -qw "$dev" && continue           # claimed
      [ -n "$(lsblk -no FSTYPE "$dev" | tr -d '[:space:]')" ] && continue
      [ "$(lsblk -no TYPE "$dev" | wc -l)" -gt 1 ] && continue   # partitioned
      echo "$dev"; return 0
    done
    sleep 5
  done
  return 1
}

# setup_lvm <disk> <vg> <lv> <mount> <label>
setup_lvm() {
  local disk=$1 vg=$2 lv=$3 mount=$4 label=$5
  if ! pvs "$disk" >/dev/null 2>&1; then
    pvcreate "$disk"
    vgcreate "$vg" "$disk"
    lvcreate -n "$lv" -l 100%FREE "$vg"
    mkfs.ext4 -L "$label" "/dev/$vg/$lv"
  fi
  mkdir -p "$mount"
  grep -q "/dev/$vg/$lv" /etc/fstab || \
    echo "/dev/$vg/$lv $mount ext4 defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q "$mount" || mount "$mount"
}

# Idempotent short-circuit: on a re-run the disks are LVM members, so
# resolve_disk (which looks for BLANK devices) would correctly find nothing
# and fail. If both LVs already exist, just ensure they're mounted.
if lvs vg_data/lv_mysql >/dev/null 2>&1 && lvs vg_content/lv_content >/dev/null 2>&1; then
  echo "LVM volumes already present; skipping disk setup"
  mkdir -p "$MYSQL_MOUNT" "$CONTENT_MOUNT"
  mountpoint -q "$MYSQL_MOUNT" || mount "$MYSQL_MOUNT"
  mountpoint -q "$CONTENT_MOUNT" || mount "$CONTENT_MOUNT"
else
  MYSQL_DISK=$(resolve_disk "$MYSQL_DISK") || { echo "mysql disk never appeared"; exit 1; }
  USED_DISKS="$MYSQL_DISK"
  CONTENT_DISK=$(resolve_disk "$CONTENT_DISK") || { echo "content disk never appeared"; exit 1; }

  # Separate VG per disk: a disk failure stays isolated to one workload, and
  # each VG can be grown independently (vgextend with another disk later).
  setup_lvm "$MYSQL_DISK"   vg_data    lv_mysql   "$MYSQL_MOUNT"   mysqldata
  setup_lvm "$CONTENT_DISK" vg_content lv_content "$CONTENT_MOUNT" ghostcontent
fi

# --- Podman + podman-compose (daemonless; no Docker Inc. involved) --------
$APT install -y podman podman-compose

grep -q '^DEPLOYMENT_BUCKET=' /etc/environment || \
  echo "DEPLOYMENT_BUCKET=$DEPLOYMENT_BUCKET" >> /etc/environment

# --- Server configuration from the public repo -----------------------------
# The repo is the versioned source of truth for config files; retry a few
# times in case of transient network/GitHub trouble at boot.
mkdir -p "$GHOST_CONFIG_DIR"
for i in 1 2 3 4 5; do
  rm -rf /tmp/config-repo
  if git clone --depth 1 "$CONFIG_REPO" /tmp/config-repo; then break; fi
  sleep 15
done

if [ -f /tmp/config-repo/configuration/ghost/config.production.json ]; then
  cp /tmp/config-repo/configuration/ghost/config.production.json \
     "$GHOST_CONFIG_DIR/config.production.json"
else
  echo "WARNING: repo config not found; writing minimal default"
  cat > "$GHOST_CONFIG_DIR/config.production.json" <<'EOF'
{
  "server": { "port": 2368, "host": "0.0.0.0" },
  "mail": { "transport": "Direct" },
  "logging": { "transports": ["file", "stdout"] }
}
EOF
fi
chmod 644 "$GHOST_CONFIG_DIR/config.production.json"

# --- Private configuration from the deployment bucket ----------------------
# Stage 3 of the config pipeline (source -> push -> PULL -> consume).
# The bucket is created AFTER this instance and the deploy pipeline pushes
# required artifacts only after CloudFormation finishes, so first boot
# blocks here: retry every 30s for up to 15 minutes until every required
# file is present. Credential-free via Lightsail resource access.
PRIVATE_CONFIG_DIR=/etc/ghost/private
REQUIRED_FILES="mysql.env"
mkdir -p "$PRIVATE_CONFIG_DIR"
IMDS_TOKEN=$(curl -fs -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)
REGION=$(curl -fs -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || echo us-east-1)

required_files_present() {
  local f
  for f in $REQUIRED_FILES; do
    [ -s "$PRIVATE_CONFIG_DIR/$f" ] || return 1
  done
  return 0
}

SYNC_OK=0
for i in $(seq 1 30); do
  aws s3 sync "s3://$DEPLOYMENT_BUCKET" "$PRIVATE_CONFIG_DIR" --region "$REGION" || true
  if required_files_present; then
    SYNC_OK=1
    break
  fi
  echo "waiting for required deployment artifacts ($REQUIRED_FILES) — attempt $i/30"
  sleep 30
done
if [ "$SYNC_OK" != "1" ]; then
  echo "FATAL: required deployment artifacts missing after 15 minutes: $REQUIRED_FILES"
  echo "Run the deploy pipeline's push stage (deployment/deploy.sh) and re-run provisioning."
  exit 1
fi
chmod -R go-rwx "$PRIVATE_CONFIG_DIR"

# --- Compose stack ----------------------------------------------------------
# Ghost runs as uid 1000 ("node") in the official image and must own content.
chown 1000:1000 "$CONTENT_MOUNT"

# Stage 4 of the config pipeline: CONSUME — must run AFTER the pull above.
# Root password comes from the synced mysql.env (pushed by the deploy
# pipeline from environments.json); the ghost app-user password is generated
# on-box and never leaves. Written once: rotating the root pw later requires
# ALTER USER on the box.
MYSQL_ROOT_PASSWORD=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$PRIVATE_CONFIG_DIR/mysql.env" | head -1 | cut -d= -f2-)
[ -n "$MYSQL_ROOT_PASSWORD" ] || { echo "FATAL: mysql.env has no MYSQL_ROOT_PASSWORD"; exit 1; }
if [ ! -f "$APP_DIR/.env" ]; then
  cat > "$APP_DIR/.env" <<EOF
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_GHOST_PASSWORD=$(openssl rand -hex 24)
EOF
  chmod 600 "$APP_DIR/.env"
fi

# Caddy terminates TLS for the journal domain: auto-obtains and renews a
# Let's Encrypt cert once DNS points here. /data must persist across
# restarts or Caddy re-requests certs (rate-limit risk).
mkdir -p "$APP_DIR/caddy-data" "$APP_DIR/caddy-config"
cat > "$APP_DIR/Caddyfile" <<EOF
{
	email $ACME_EMAIL
}

$JOURNAL_DOMAIN {
	encode zstd gzip
	reverse_proxy ghost:2368
}
EOF

# Bare-apex redirect (prod): geek.dev -> www.geek.dev. Caddy auto-issues
# the apex cert; needs an apex A record pointing at this instance.
if [ -n "$APEX_REDIRECT_DOMAIN" ]; then
  cat >> "$APP_DIR/Caddyfile" <<EOF

$APEX_REDIRECT_DOMAIN {
	redir https://$JOURNAL_DOMAIN{uri} permanent
}
EOF
fi

# Notes for podman:
# - Fully qualified image names (docker.io/...) so no registry prompt.
# - restart: always covers in-life crash restarts (podman's cleanup process
#   honors it); boot-time startup is handled by ghost-compose.service below.
# - No depends_on healthy-condition: ghost simply restarts until MySQL
#   accepts connections.
cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  mysql:
    image: docker.io/library/mysql:8.0
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: \${MYSQL_GHOST_PASSWORD}
    volumes:
      - $MYSQL_MOUNT:/var/lib/mysql

  ghost:
    image: docker.io/library/ghost:5
    restart: always
    depends_on:
      - mysql
    environment:
      url: https://$JOURNAL_DOMAIN
      database__client: mysql
      database__connection__host: mysql
      database__connection__user: ghost
      database__connection__password: \${MYSQL_GHOST_PASSWORD}
      database__connection__database: ghost
    volumes:
      - $CONTENT_MOUNT:/var/lib/ghost/content
      # Config from the repo (staged to /etc/ghost by provisioning). Ghost
      # reads config.production.json from its install dir. The compose env
      # vars above (url, database__*) intentionally override the file.
      - $GHOST_CONFIG_DIR/config.production.json:/var/lib/ghost/config.production.json:ro

  caddy:
    image: docker.io/library/caddy:2
    restart: always
    depends_on:
      - ghost
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $APP_DIR/Caddyfile:/etc/caddy/Caddyfile:ro
      - $APP_DIR/caddy-data:/data
      - $APP_DIR/caddy-config:/config
EOF

# --- systemd unit: bring the composition up on every boot ------------------
# Replaces podman-restart.service: also recreates missing containers, waits
# for the network, and refuses to start before the LVM mounts are in place
# (RequiresMountsFor), so MySQL can never launch against an empty mountpoint.
cat > /etc/systemd/system/ghost-compose.service <<EOF
[Unit]
Description=Ghost CMS + MySQL compose stack (podman-compose)
Wants=network-online.target
After=network-online.target
RequiresMountsFor=$MYSQL_MOUNT $CONTENT_MOUNT

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ghost-compose.service
echo "provisioning complete"
