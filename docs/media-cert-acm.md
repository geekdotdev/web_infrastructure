# Media cert: `cfmedia-<env>.geek.dev` (ACM, manual, once per environment)

Serves the CloudFront media distribution's custom domain. Requested manually —
**not** part of the deploy pipeline — because it happens once per env, requires
a human paste into the root account's DNS, and its output (the ARN) becomes
static config that every subsequent deploy consumes.

## Prerequisites

- The `geek.dev` hosted zone exists in the **root account** and Namecheap's
  nameservers point at it (Domain → Nameservers → Custom DNS).
- The env's AWS profile is configured locally (see the `profile` attribute in your local `environments.json`).
- Timing: ACM gives you **72 hours** to publish the validation record before
  the request expires — don't start until you can paste into the zone.

## Steps

1. Request the cert. It must live in the **env's account** (same account as
   the distribution) and in **us-east-1** (CloudFront requirement). The script
   handles both:

   ```sh
   scripts/request-cert.sh prod                # profile read from environments.json
   scripts/request-cert.sh dev dev-profile     # or pass a profile explicitly
   ```

2. The script prints a DNS validation CNAME. Create it in the `geek.dev`
   hosted zone (root account). **Leave it in place permanently** — ACM uses it
   to auto-renew forever; delete it and renewal silently breaks.

3. The script waits for issuance (ctrl-c is safe; issuance continues
   server-side) and prints the certificate ARN.

4. Add the ARN to the env's entry in `environments.json`:

   ```json
   "mediaCertificateArn": "arn:aws:acm:us-east-1:<account>:certificate/<id>"
   ```

5. Deploy: `deployment/deploy.sh <env>`. The stack attaches the alias
   (`cfmedia-<env>.geek.dev`) and cert to the distribution (TLS 1.2, SNI).

6. In the root account's zone, CNAME `cfmedia-<env>.geek.dev` to the
   `MediaDistributionDomain` stack output (`deployment/outputs/<env>.json`).

7. Verify: `scripts/check-cert.sh cfmedia-<env>.geek.dev`.

## Notes

- Before step 4, the stack deploys fine without the ARN — media serves from
  the default `*.cloudfront.net` domain; the `MediaCustomDomain` output shows
  pending/active status.
- Renewal is automatic and free; nothing recurring to do. `check-cert.sh`
  warning under 21 days means the validation CNAME was probably deleted.
- Never request this cert via CDK/CloudFormation: the deploy would block
  mid-stack waiting on the cross-account DNS paste, and certs attached to
  live distributions resist stack replace/delete.
