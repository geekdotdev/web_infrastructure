#!/bin/bash
# First-boot provisioning: LVM on the two attached Lightsail disks, Podman,
# and a Ghost CMS + MySQL compose stack (podman-compose, rootful).
set -euxo pipefail
exec > /var/log/ghost-provision.log 2>&1

MYSQL_DISK="__MYSQL_DISK_PATH__"
CONTENT_DISK="__CONTENT_DISK_PATH__"
JOURNAL_DOMAIN="__JOURNAL_DOMAIN__"
ACME_EMAIL="__ACME_EMAIL__"
MYSQL_MOUNT=/srv/ghost/mysql-data
CONTENT_MOUNT=/srv/ghost/content
APP_DIR=/srv/ghost

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y lvm2 ca-certificates curl

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

MYSQL_DISK=$(resolve_disk "$MYSQL_DISK") || { echo "mysql disk never appeared"; exit 1; }
USED_DISKS="$MYSQL_DISK"
CONTENT_DISK=$(resolve_disk "$CONTENT_DISK") || { echo "content disk never appeared"; exit 1; }

# Separate VG per disk: a disk failure stays isolated to one workload, and
# each VG can be grown independently (vgextend with another disk later).
setup_lvm "$MYSQL_DISK"   vg_data    lv_mysql   "$MYSQL_MOUNT"   mysqldata
setup_lvm "$CONTENT_DISK" vg_content lv_content "$CONTENT_MOUNT" ghostcontent

# --- Podman + podman-compose (daemonless; no Docker Inc. involved) --------
apt-get install -y podman podman-compose

# --- Compose stack ----------------------------------------------------------
# Ghost runs as uid 1000 ("node") in the official image and must own content.
chown 1000:1000 "$CONTENT_MOUNT"

if [ ! -f "$APP_DIR/.env" ]; then
  cat > "$APP_DIR/.env" <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
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
