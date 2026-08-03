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
deployment/destroy.sh prod
```

Confirm when prompted. This deletes the instance, both disks, the static IP,
the deployment bucket, and the CloudFront distribution. The media bucket
(RETAIN in prod) and the ACM cert are unaffected — the bucket is **orphaned**,
not deleted: it survives in your account but is no longer part of any stack.

### The stale media CNAME trap

Destroying the stack deletes the CloudFront distribution. If the media
subdomain's CNAME (`cfmedia-<env>.geek.dev`) is still in the root account's
zone pointing at that now-gone distribution, the **next** deploy's
`CREATE_FAILED` on `AWS::CloudFront::Distribution` with "incorrectly
configured DNS record that points to another CloudFront distribution" —
CloudFront does a live DNS lookup when assigning an alias and refuses one
that currently resolves to a different distribution (anti-hijacking check).
`destroy.sh` prints an explicit reminder of this after every run. Delete
that CNAME before redeploying; recreate it (pointed at the new
`MediaDistributionDomain` output) only after the deploy succeeds. This only
bites recreate cycles — a true first-ever deploy has no stale record yet.

### The "bucket already exists" trap

Because the retained bucket keeps its name, the **next** `deploy` fails with
`Resource of type 'AWS::S3::Bucket' ... already exists` — S3 names are
globally unique, so CloudFormation can't create a new bucket with the name
an orphaned one still holds. If you're doing a real teardown-and-forget, this
is fine to leave as-is (redeploying isn't the plan). If you're cycling
through test destroys, either:

```sh
deployment/destroy.sh prod --purge-media
```

which empties (all versions/delete markers) and deletes the bucket right
after the stack destroy completes — it prompts you to type the bucket name
to confirm (or set `CONFIRM_PURGE=yes` to skip the prompt non-interactively).
Or clean up manually:

```sh
aws s3 rm s3://geek-dot-dev-media-primary-prod --recursive --region us-east-1 --profile <profile>
aws s3api delete-bucket --bucket geek-dot-dev-media-primary-prod --region us-east-1 --profile <profile>
```

Either way, use this deliberately — it defeats the entire point of `RETAIN`,
which exists so a real production teardown can't take member media with it.

## Restarting (recreating) the stack

Nothing about the CDK code or `environments.json` needs to change — the
account is already bootstrapped, and the cert ARN is still valid.

```sh
deployment/deploy.py prod
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
