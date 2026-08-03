# Post-deploy steps (per environment)

Run these after `deployment/deploy.sh <env>` completes. Values referenced
below come from the stack outputs in `deployment/outputs/<env>.json`.

## 1. Create DNS records (root account, `geek.dev` hosted zone)

| Record | Type | Value |
| --- | --- | --- |
| `<journalSubdomain>.geek.dev` (e.g. `www`) | A | `StaticIpAddress` output |
| `geek.dev` (apex — **prod only**) | A | prod's `StaticIpAddress` output |
| `cfmedia-<env>.geek.dev` | CNAME | `MediaDistributionDomain` output |

Notes:
- The apex record is prod-only: prod's Caddy serves `geek.dev` as a 301 to
  `www.geek.dev` and auto-issues its cert.
- The `cfmedia` CNAME requires `mediaCertificateArn` to have been deployed
  (otherwise the distribution has no alias for that name yet).

## 2. Wait for the journal TLS cert, then verify

Caddy starts requesting its Let's Encrypt cert as soon as the A record
resolves — typically live within a minute or two. Verify:

```sh
scripts/check-cert.sh <journalSubdomain>.geek.dev
scripts/check-cert.sh geek.dev                    # prod only
scripts/check-cert.sh cfmedia-<env>.geek.dev      # after the CNAME lands
```

If the journal cert doesn't appear after a few minutes:
`dig +short <journalSubdomain>.geek.dev` (must return the static IP), then
check Caddy's logs on the box: `cd /srv/ghost && sudo podman-compose logs caddy`.

## 3. Claim the Ghost owner account — promptly

Open `https://<journalSubdomain>.geek.dev/ghost` and complete the one-time
setup screen (site title, name, email, password). **Do this immediately after
the cert goes green**: until setup is completed, the screen is open to whoever
reaches it first, and new certs are publicly logged in certificate-transparency
feeds that bots watch. Setup disables itself permanently once the owner
account exists.

The password is stored bcrypt-hashed in MySQL (on the `vg_data` volume); it is
not part of the deployment pipeline. Resets later go through the admin UI —
note that email-based reset needs a real SMTP provider configured (the default
`mail.transport: Direct` is unreliable).
