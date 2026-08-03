# Destroying and restarting the stack

## Read this first: Lightsail billing and data loss

**Stopping ≠ saving money.** Lightsail bills its flat monthly bundle rate for
as long as the instance *exists*, whether it's running or stopped (unlike
EC2, where a stopped instance only costs its EBS storage). The only way to
actually stop paying is to delete the stack.

**Deleting the stack deletes your data.** The MySQL and Ghost-content disks
have no retain policy — `cdk destroy` removes them along with the instance.
That means: the admin account you just created, all Ghost content, and
Caddy's TLS state are **gone** on destroy. There is no in-CDK snapshot/restore
path for `AWS::Lightsail::Instance` — CloudFormation can create a fresh
instance from a blueprint, but not from a snapshot. A pre-destroy snapshot
can only be restored manually via the console/CLI, and the resulting
instance falls **outside** CDK's management (it's no longer the stack's
instance) — that's a real fork in how the environment is managed, not a
one-line recovery step.

**What survives destroy regardless:**
- `environments.json` (local) — account, profile, cert ARN, passwords
- The prod media bucket — `RETAIN` policy, survives stack deletion
- The ACM media certificate — lives in ACM, independent of the stack
- The Let's Encrypt validation CNAME in the root-account zone (don't touch it)

**What does NOT survive:** static IP (a new one is issued on recreate — DNS
must be updated), the deployment bucket and its contents, MySQL data, Ghost
content, the Ghost admin account, Caddy's cert/account-key state (auto
reissues, but see the rate-limit note below).

**Recommendation:** if you're pausing for a day or a week, leave the stack
running — the cost of the bundle is small relative to redoing setup. Only
destroy if you're stepping away for an extended period and are comfortable
recreating the Ghost owner account from scratch afterward.

## Destroying the stack

```sh
npx cdk destroy -c env=prod --profile <prod-profile>   # or omit --profile: read from environments.json
```

Confirm when prompted. This deletes the instance, both disks, the static IP,
the deployment bucket, and the CloudFront distribution. The media bucket and
ACM cert are unaffected.

## Restarting (recreating) the stack

Nothing about the CDK code or `environments.json` needs to change — the
account is already bootstrapped, and the cert ARN is still valid.

```sh
deployment/deploy.sh prod
```

This runs the full pipeline: synth, deploy (new instance, new disks, new
static IP, new deployment bucket, new distribution), then pushes `mysql.env`
to the new deployment bucket automatically.

### After it comes back up

1. **Update DNS** — the static IP changed. In the root account's `geek.dev`
   zone, update the A records to the new `StaticIpAddress` output (both
   `www.geek.dev` and the apex `geek.dev`). The `cfmedia-prod` CNAME target
   (`MediaDistributionDomain`) typically stays the same distribution domain
   format but reconfirm from `deployment/outputs/prod.json`.
2. **Wait for Caddy's cert** — a few minutes after DNS propagates. Verify
   with `scripts/check-cert.sh www.geek.dev`.
3. **Recreate the Ghost owner account** at the sign-in/setup link below —
   it's a fresh MySQL datadir, so setup runs again from scratch.
4. Full first-boot troubleshooting (dpkg lock, disk resolution, etc.) is the
   same as any fresh instance — see the provisioning notes accumulated during
   the initial deploy if anything stalls.

### Rate-limit note

Let's Encrypt allows 5 certificates for the same domain set per rolling week.
Destroying and recreating prod repeatedly in a short window will exhaust
that and block issuance for several days. Fine for occasional recreation;
avoid doing it as a routine on/off switch.

## Admin sign-in

`https://www.geek.dev/ghost/`

(Only valid once DNS points at the current instance and Caddy has obtained
its certificate — see steps above after any recreate.)
