# Media pipeline checklist

Remaining work to get media fully flowing: bucket → Ghost storage adapter → CloudFront → custom domains. Items already in the stack are marked done.

## Already done (in CDK / repo)

- [x] Media bucket `geek-dot-dev-media-primary-<env>` (real S3: private, SSL-enforced, versioned lifecycle by env)
- [x] CloudFront distribution with OAC (bucket readable only by CloudFront), HTTPS-only
- [x] Trusted key group — all requests require signed URLs/cookies
- [x] Custom-domain wiring: alias + ACM cert attach automatically when `mediaCertificateArn` appears in `environments.json`
- [x] `scripts/request-cert.sh` (ACM request + validation flow), `scripts/check-cert.sh` (expiry check)
- [x] Deployment-bucket secret pipeline (source → push → pull → consume) for delivering credentials to the instance
- [x] Docs: `docs/media-cert-acm.md`, `docs/journal-cert-letsencrypt.md`

## 0. Foundations (blocking everything else)

- [ ] Create `geek.dev` hosted zone in the root/org account
- [ ] Point Namecheap at the zone's nameservers (Domain → Nameservers → Custom DNS); recreate any existing DNS records (email!) in the zone first
- [ ] Regenerate CloudFront signing key pairs locally for each env (`openssl genrsa` per README) — do NOT use the sandbox-generated `keys/dev-*.pem` test pair
- [ ] Regenerate `mysqlRootPassword` values in `environments.json` (current ones appeared in the Claude chat transcript)
- [ ] Set real `acmeEmail` values in `environments.json` (currently `test@example.com`)
- [ ] Delete repo litter: `deployment/dry-run.sh`, `deployment/deploy.sh.bak`, stale `.git/index.lock`
- [ ] `brew install gitleaks` so the pre-commit hook's secret scan is active

## 1. Cert requests (per env; prod first)

- [ ] `scripts/request-cert.sh prod` → paste validation CNAME into the zone (leave it forever) → wait for issuance
- [ ] Add ARN to prod's `environments.json` as `mediaCertificateArn`
- [ ] Repeat for dev/qa when those accounts exist
- [ ] Journal certs: nothing to request (Caddy/Let's Encrypt) — just DNS below

## 2. DNS records (root-account zone, per env)

- [ ] A record `<journalSubdomain>.geek.dev` → env's `StaticIpAddress` output
- [ ] Prod only: apex A record `geek.dev` → prod static IP (Caddy serves the 301 → www)
- [ ] CNAME `cfmedia-<env>.geek.dev` → `MediaDistributionDomain` output (after cert ARN deployed)

## 3. Media bucket write path (CDK work)

- [ ] Add scoped IAM user/policy to the stack: `s3:PutObject/GetObject/DeleteObject/ListBucket` on the media bucket ARN only
- [ ] Create access key at deploy time; deliver as `s3.env` via the push stage (alongside `mysql.env`)
- [ ] Add `s3.env` to `REQUIRED_FILES` in `assets/user-data.sh`
- [ ] Inject `storage__s3__*` env vars into the ghost container from `s3.env`

## 4. Ghost storage adapter

- [ ] Pick an S3 storage adapter fork (original `ghost-storage-adapter-s3` is unmaintained) and pin by commit
- [ ] Install it into the ghost container (bake a small custom image, or mount into `content/adapters/storage/s3`)
- [ ] Configure: `bucket`, `region`, `assetHost: https://cfmedia-<env>.geek.dev`, `pathPrefix`, credentials via env vars (never in the public repo's `config.production.json`)
- [ ] **Decision required first:** public vs private serving. The distribution currently signs *everything*, so adapter-embedded image URLs would 403 for readers. Options:
  - [ ] add an unsigned CloudFront behavior for a public path (e.g. `/images/*`), keep signing for private prefixes, or
  - [ ] keep everything signed and issue signed cookies at member login (needs middleware; members-only sites)

## 5. Verify

- [ ] `deployment/deploy.py <env>` runs clean end-to-end (incl. artifact push)
- [ ] `scripts/check-cert.sh <journalSubdomain>.geek.dev` and `scripts/check-cert.sh cfmedia-<env>.geek.dev` both green
- [ ] Upload an image in Ghost admin → confirm it lands in the media bucket and serves from `cfmedia-<env>.geek.dev`
- [ ] Confirm a direct S3 URL for the same object returns 403 (OAC working)
- [ ] Reboot the instance (`ghost-compose.service` + mounts + certs all come back)
