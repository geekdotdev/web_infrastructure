# web_infrastructure

CDK (TypeScript) stack that provisions a single Amazon Lightsail instance running Ghost CMS + MySQL via podman-compose (daemonless, no Docker). MySQL data and Ghost content each live on their own LVM logical volume, each backed by a dedicated 20 GB Lightsail block-storage disk (sized small to start — LVM makes growing them a no-downtime operation).

> **Note on EBS:** Lightsail instances cannot attach EBS volumes. Lightsail block storage is the SSD-backed equivalent; the LVM layout (`vg_data/lv_mysql`, ext4, mounted at `/srv/ghost/mysql-data`) is identical to what you'd build on EBS. Lightsail also has no autoscaling, so "scaled to 1" is exactly one instance.

## What gets created

- `AWS::Lightsail::Instance` — Ubuntu 24.04 (ships podman 4.9 + podman-compose), `medium_3_0` bundle (2 vCPU / 4 GB). Ports 80/443 open; **port 22 has no public exposure** — SSH only via the Lightsail console's browser terminal (`lightsail-connect` firewall alias)
- `AWS::Lightsail::Disk` ×2 — 20 GB MySQL disk at `/dev/xvdf`, 20 GB Ghost content disk at `/dev/xvdg`
- `AWS::Lightsail::StaticIp` — attached to the instance
- `geek-dot-dev-deployment-resources-<env>` Lightsail bucket — private, versioned, reserved for per-env configuration that can't live in the public repo. Created **after** the instance so `resourcesReceivingAccess` can grant the instance credential-free read access in the same deploy (bucket names are deterministic, so the boot script gets the name injected up front as `DEPLOYMENT_BUCKET`, also persisted to `/etc/environment`)
- `geek-dot-dev-media-primary-<env>` S3 bucket — private (all public access blocked, SSL enforced), primary store for images/video. `RETAIN`ed on stack deletion in prod, deletable elsewhere
- CloudFront distribution in front of the bucket via Origin Access Control (only CloudFront can read it), HTTPS-only, with a trusted key group — every request must carry a **signed URL or signed cookie** or it gets a 403
- First-boot user data (`assets/user-data.sh`):
  1. Waits for both disks (handles xvd/nvme naming; nvme fallback skips already-claimed devices)
  2. LVM per disk, separate VGs so a disk failure is isolated to one workload:
     - `vg_data/lv_mysql` → ext4 → `/srv/ghost/mysql-data`
     - `vg_content/lv_content` → ext4 → `/srv/ghost/content` (chowned to uid 1000 for the Ghost image)
  3. Installs podman + podman-compose
  4. Generates MySQL passwords into `/srv/ghost/.env` (mode 600)
  4a. Syncs the deployment bucket to `/etc/ghost/private/` (owner-only perms) — retries every 30s for up to 6 minutes since the bucket is created after the instance; non-fatal if empty/absent. Clones this repo (public, no credentials) and installs `configuration/ghost/config.production.json` to `/etc/ghost/`; the Ghost container mounts it read-only as its config file. Compose env vars (`url`, `database__*`) intentionally override the file for runtime-derived values. To change Ghost config: edit `configuration/ghost/config.production.json`, push, then re-run provisioning or copy + `sudo systemctl restart ghost-compose` on the box
  5. Writes `/srv/ghost/Caddyfile` and `/srv/ghost/docker-compose.yml` (caddy:2 + ghost:5 + mysql:8.0 from docker.io). Caddy owns ports 80/443, terminates TLS for the journal domain with an auto-obtained/auto-renewed Let's Encrypt cert, and reverse-proxies to `ghost:2368`; Ghost's `url` is `https://<journalSubdomain>.geek.dev`. Cert state persists in `/srv/ghost/caddy-data`
  6. Installs and starts `ghost-compose.service` — a systemd unit that runs `podman-compose up -d` at boot, ordered after the network and the LVM mounts (`RequiresMountsFor`), with `podman-compose down` on stop. Manage the stack with `sudo systemctl {start,stop,status} ghost-compose`. In-life crash restarts are covered by podman's `restart: always`.

Caddy's parameters come from `environments.json`: the journal domain is derived from `journalSubdomain` + `APEX_DOMAIN`, and `acmeEmail` (required) is the Let's Encrypt registration address. Note: the TLS cert can only be issued after the journal DNS A record points at the instance's static IP — until then Caddy retries in the background and the site is unreachable by domain (expected).

To grow either volume later: attach another disk, then `pvcreate` → `vgextend <vg>` → `lvextend -r -l +100%FREE <lv>` — online, no downtime.

## Environments

Each environment (dev, qa, prod, ...) is fully siloed in its own AWS account. The account mapping lives in `environments.json` — local only, gitignored:

```sh
cp environments.json.example environments.json   # then fill in real account numbers
```

Every resource name is suffixed with the env label (`ghost-cms-dev`, `ghost-mysql-data-dev`, ...), and the stack is named `GhostLightsailStack-<env>`. The env label is a **required** CLI arg — synth/deploy fail without it.

Each env also carries two subdomain attributes (conventions applied automatically if omitted from `environments.json`):

- `journalSubdomain` — the Ghost site; env label, except prod uses `www`. Point `<journalSubdomain>.<your-domain>` at the env's static IP.
- `mediaSubdomain` — the CloudFront media host; `cfmedia-<env>`. Combined with the apex domain (the `APEX_DOMAIN` const in `bin/web_infrastructure.ts`, currently `geek.dev`) this yields the distribution's custom domain, e.g. `cfmedia-dev.geek.dev`.

Both are emitted as stack outputs.

Step-by-step cert guides: [docs/media-cert-acm.md](docs/media-cert-acm.md) (manual, once per env) and [docs/journal-cert-letsencrypt.md](docs/journal-cert-letsencrypt.md) (automatic via Caddy).

### Enabling the custom media domain

CloudFront won't accept an alias without a covering TLS cert, so the custom domain activates in two steps once DNS/TLS are ready:

1. Run `scripts/request-cert.sh <env> [aws-profile]` — requests the cert in the env account (us-east-1, a CloudFront requirement regardless of stack region), prints the validation CNAME to paste into the geek.dev zone in the root account, waits for issuance, and prints the ARN. Put the ARN in that env's `environments.json` entry as `mediaCertificateArn` and redeploy — the alias + cert attach to the distribution. (Certs are deliberately *not* CDK-managed: the CloudFormation ACM resource blocks mid-deploy on the cross-account validation paste, and certs attached to live distributions resist stack replace/delete.)
2. CNAME `cfmedia-<env>.geek.dev` to the `MediaDistributionDomain` output.

Until then the distribution serves from its default `*.cloudfront.net` domain; the `MediaCustomDomain` output shows pending/active status. Note `.dev` is an HSTS-preloaded TLD — browsers force HTTPS — which is fine since the distribution is HTTPS-only.

## CloudFront signing keys

Each env needs an RSA key pair for signing media URLs/cookies. Only the public half goes to AWS; both live in `keys/` (gitignored):

```sh
mkdir -p keys
openssl genrsa -out keys/dev-private.pem 2048
openssl rsa -pubout -in keys/dev-private.pem -out keys/dev-public.pem
```

Synth/deploy fail if `keys/<env>-public.pem` is missing. After deploy, sign with the private key + the `MediaKeyPairId` output, e.g.:

```sh
aws cloudfront sign \
  --url "https://<MediaDistributionDomain>/hero.jpg" \
  --key-pair-id <MediaKeyPairId> \
  --private-key file://keys/dev-private.pem \
  --date-less-than 2026-12-31
```

or in an app via the AWS SDK's CloudFront signer (URLs for individual objects, cookies for whole-site media access).

## Deploy

```sh
npm install
# once per account/region:
npx cdk bootstrap -c env=dev --profile dev

# the MVP pipeline (preflight → synth → deploy → post-deploy):
deployment/deploy.sh dev            # or: npm run deploy dev
deployment/deploy.sh prod prod-admin --require-approval never
```

`deployment/deploy.sh <env> [aws-profile] [extra cdk args...]` validates `environments.json` and the env's signing key, type-checks, synths, deploys, pushes private artifacts, and writes stack outputs to `deployment/outputs/<env>.json` (gitignored). The AWS profile is **required**: pass it as the second argument or set the env's `profile` attribute in `environments.json` — the script refuses to fall back to the default credential chain, and verifies the profile exists in `~/.aws/config` or `~/.aws/credentials`.

### Private configuration pipeline

Secrets reach the instance in four stages, never touching the CloudFormation template:

1. **Source** — `mysqlRootPassword` in `environments.json` (local, gitignored), plus any files in `private-config/<env>/` (gitignored).
2. **Push** — after `cdk deploy`, the pipeline stages `mysql.env` (+ `private-config/<env>/*`) and uploads them to the deployment bucket using an ephemeral Lightsail bucket access key (created → used → deleted).
3. **Pull** — instance first boot syncs the bucket to `/etc/ghost/private/` (owner-only perms), blocking until every **required file** (`mysql.env`; the list is the `REQUIRED_FILES` var in `assets/user-data.sh`) is present — retries every 30s for up to 15 minutes, then fails the provision loudly.
4. **Consume** — `/srv/ghost/.env` takes the root password from the synced `mysql.env`; the ghost DB-user password is still generated on-box. MySQL only uses the root password when initializing an empty datadir; rotating it later means `ALTER USER` on the box, not a redeploy. Its phases are functions, intended to grow into the full pipeline (artifact push to the deployment bucket, smoke tests, DNS checks).

Deploy one environment at a time; credentials must match the account pinned in `environments.json` — CDK refuses otherwise.

Provisioning log: `/var/log/ghost-provision.log` on the instance. Manage the stack on-box with `cd /srv/ghost && podman-compose ...` (rootful, so use sudo).

## After deploy

Full checklist: [docs/post-deploy.md](docs/post-deploy.md) (DNS records → cert verification → claim the Ghost owner account).

To shut down and later recreate an environment, read [docs/destroy-and-restart.md](docs/destroy-and-restart.md) first — Lightsail bills the same whether stopped or running, so pausing means destroying, and destroying deletes the MySQL/content disks (no snapshot-restore path exists in CDK for Lightsail instances).

- Create the journal A record (`<journalSubdomain>.geek.dev` → `StaticIpAddress` output) in the root account's hosted zone. Within a minute or two Caddy obtains the cert and `https://<journalSubdomain>.geek.dev/ghost` is live. (`.dev` is HSTS-preloaded, so the site is HTTPS-or-nothing by design — there's no pre-DNS IP-based preview.)
- **Prod only:** also create an apex A record (`geek.dev` → prod's static IP). Prod's Caddyfile serves the bare apex as a permanent redirect to `www.geek.dev` and auto-issues the apex cert.

## Config

Bundle, blueprint, disk sizes, and AZ are props in `bin/web_infrastructure.ts`.
