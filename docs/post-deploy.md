# Post-deploy steps (per environment)

Run these after `deployment/deploy.py <env>` completes. Values referenced
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

If the journal cert doesn't appear after a few minutes, see Troubleshooting
below.

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

## Troubleshooting

### Watch first-boot provisioning

The instance runs a first-boot script (LVM setup, podman install, pulling
the compose stack) before Caddy can do anything — this takes a few minutes
and is worth watching directly rather than guessing. Connect via the
Lightsail console's **Connect** tab (browser-based SSH — port 22 has no
public exposure by design), then:

```sh
sudo tail -f /var/log/ghost-provision.log
```

Success looks like the log ending in `provisioning complete`. If it's still
running, you'll see steps like disk/LVM setup, `waiting for required
deployment artifacts (mysql.env) — attempt N/30` (normal for a minute or two
after a `deploy`, since the deployment bucket's artifact push happens after
the stack finishes creating), or apt/package output. A `FATAL` line means it
gave up — the message names the cause (usually a missing `mysql.env`, meaning
the deploy pipeline's push step didn't complete) and re-running
`sudo bash /var/lib/cloud/instance/scripts/part-001` after fixing it is safe
(every step is idempotent).

If the log file doesn't exist at all, the boot script never ran — check
`/var/log/cloud-init-output.log` instead.

### Cert not appearing: is Caddy even up?

Before suspecting DNS or Let's Encrypt, check whether Caddy is listening and
answering HTTP at all — this tells apart "not up yet" from "up but the
challenge is failing":

```sh
curl -sI http://<journalSubdomain>.geek.dev/.well-known/acme-challenge/probe
```

- **Connection refused / timeout** — Caddy (or the whole compose stack)
  isn't up yet. Go watch the provisioning log above.
- **Any HTTP response (even 404)** — Caddy is listening and issuance is in
  progress or actively failing; give it another minute, then check further.

### Cert still not appearing after Caddy is confirmed up

```sh
dig +short <journalSubdomain>.geek.dev              # must return the static IP
cd /srv/ghost && sudo podman-compose logs caddy     # the actual ACME error
```

Common causes: the A record is missing, wrong, or hasn't propagated yet; the
apex record is missing on prod (Caddy also requests a cert for `geek.dev`
there); or `/srv/ghost/caddy-data` was wiped, which can trip Let's Encrypt's
weekly rate limit on repeated issuance for the same name (see
`docs/destroy-and-restart.md`).

### DNS was wrong, then fixed — Caddy still hasn't picked it up

If Caddy started (or kept retrying) while DNS pointed at the wrong IP, it's
now on its own exponential backoff schedule for retrying — per Caddy's docs,
that can be anywhere from a brief pause up to **1 day between attempts, for
up to 30 days** before it gives up. It does *not* re-check sooner just
because DNS is now correct; it waits for its own clock. Once DNS is fixed,
force an immediate retry instead of waiting:

```sh
cd /srv/ghost && sudo podman-compose restart caddy
```

This discards Caddy's in-memory backoff state and re-triggers its normal
startup behavior of obtaining certs for every configured hostname right
away. With DNS now correct, this attempt should succeed immediately.
