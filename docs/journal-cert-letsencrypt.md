# Journal cert: `<journalSubdomain>.geek.dev` (Let's Encrypt via Caddy, automatic)

Serves the Ghost site (`dev.geek.dev`, `qa.geek.dev`, `www.geek.dev` — plus the
bare apex `geek.dev` in prod, which Caddy 301-redirects to `www`). **There is
nothing to request**: Caddy obtains and renews these certs itself. This doc
covers the conditions that must hold and how to verify.

## How it works

- Caddy (in the compose stack) is configured by first-boot provisioning with
  the env's journal domain and `acmeEmail` from `environments.json`.
- On startup it generates an ACME account key (no username/password — ACME
  identity is a keypair), proves control of the domain via an HTTP-01 /
  TLS-ALPN-01 challenge on ports 80/443, and installs the cert.
- Certs last 90 days; Caddy renews around day 60, forever. Let's Encrypt
  stopped sending expiry-warning emails in June 2025, so external checks are
  the safety net.

## Conditions that must hold

1. **DNS**: A record `<journalSubdomain>.geek.dev` → the env's static IP
   (`StaticIpAddress` in `deployment/outputs/<env>.json`). Prod additionally
   needs an apex A record `geek.dev` → the same IP.
2. **Ports**: 80 and 443 open to the world (already true in the stack — the
   Lightsail firewall opens both; only SSH is restricted).
3. **Cert state persists**: `/srv/ghost/caddy-data` survives restarts (it's on
   the instance). Losing it forces re-issuance and risks Let's Encrypt rate
   limits.

## Steps (per environment)

1. Deploy the env: `deployment/deploy.sh <env>`.
2. Create the A record(s) in the root account's `geek.dev` zone (see above).
   Until DNS exists, Caddy retries issuance quietly in the background —
   expected, not an error.
3. Wait a minute or two after DNS propagates.
4. Verify: `scripts/check-cert.sh <journalSubdomain>.geek.dev`
   (and `scripts/check-cert.sh geek.dev` for prod).
   `https://<journalSubdomain>.geek.dev/ghost` should serve the Ghost admin.

## Troubleshooting

- On the instance (Lightsail console → Connect/browser SSH):
  `cd /srv/ghost && sudo podman-compose logs caddy`
- Common causes of failed issuance: A record missing/wrong, DNS not yet
  propagated, port 80 closed, or `caddy-data` wiped (rate-limited — wait, the
  limit window is one week).
- `check-cert.sh` reporting < 21 days remaining means renewal has been failing
  for weeks — read the Caddy logs; do not wait for expiry.
