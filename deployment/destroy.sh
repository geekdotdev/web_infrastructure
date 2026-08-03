#!/usr/bin/env bash
# Destroy one environment's stack — same strict profile resolution logic
# as deploy.py's (see lib/common.sh). Calling `cdk destroy` directly bypasses
# that resolution entirely: profile is a CDK CLI concept the app cannot
# supply, so a bare `cdk destroy -c env=X` falls through to whatever
# default credentials your shell happens to have. This wrapper exists so
# destroy can't silently target the wrong account any more than deploy can.
#
# Usage: deployment/destroy.sh <env> [aws-profile] [--purge-media] [extra cdk args...]
#   e.g. deployment/destroy.sh dev
#        deployment/destroy.sh prod prod-admin
#        deployment/destroy.sh prod --purge-media
#
# --purge-media: the media bucket (geek-dot-dev-media-primary-<env>) has
# RemovalPolicy.RETAIN in prod, so a plain destroy ORPHANS it (it survives,
# but leaves the stack) rather than deleting it — protecting real member
# content from an accidental teardown. That protection becomes a footgun
# during throwaway test cycles: the next deploy fails with "bucket already
# exists" because S3 names are globally unique. This flag empties (all
# object versions + delete markers) and deletes that bucket after the stack
# destroy completes. It requires typed confirmation of the exact bucket
# name — skip the prompt non-interactively with CONFIRM_PURGE=yes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_LABEL="${1:?usage: destroy.sh <env> [aws-profile] [--purge-media] [extra cdk args...]}"
shift
PROFILE="${1:-}"
if [ -n "$PROFILE" ] && [[ "$PROFILE" != --* ]]; then
  shift
else
  PROFILE=""
fi

PURGE_MEDIA=0
REMAINING=()
for arg in "$@"; do
  if [ "$arg" = "--purge-media" ]; then
    PURGE_MEDIA=1
  else
    REMAINING+=("$arg")
  fi
done
EXTRA_ARGS=("${REMAINING[@]:-}")
[ "${#REMAINING[@]}" -eq 0 ] && EXTRA_ARGS=()

# shellcheck source=./lib/common.sh
source "$REPO_ROOT/deployment/lib/common.sh"
resolve_profile

log "WARNING: this deletes the instance, both data disks, the static IP,"
log "and the deployment bucket for '$ENV_LABEL'. See docs/destroy-and-restart.md."
log "destroying GhostLightsailStack-$ENV_LABEL via profile '$PROFILE'"

cd "$REPO_ROOT"
npx cdk destroy -c "env=$ENV_LABEL" "${PROFILE_ARGS[@]}" "${EXTRA_ARGS[@]}"
log "destroyed at $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u '+%H:%M:%S UTC'))"

if [ "$PURGE_MEDIA" = "1" ]; then
  BUCKET="geek-dot-dev-media-primary-$ENV_LABEL"
  REGION=$(python3 -c "
import json
print(json.load(open('$REPO_ROOT/environments.json')).get('$ENV_LABEL', {}).get('region', 'us-east-1'))
")

  if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" "${PROFILE_ARGS[@]}" 2>/dev/null; then
    log "media bucket $BUCKET does not exist (already gone) — nothing to purge"
  else
    log "WARNING: about to permanently empty and delete $BUCKET"
    if [ "${CONFIRM_PURGE:-}" != "yes" ]; then
      read -r -p ">>> [$ENV_LABEL] Type the bucket name to confirm deletion: " TYPED
      if [ "$TYPED" != "$BUCKET" ]; then
        echo "ERROR: confirmation did not match '$BUCKET' — aborting purge (stack destroy already completed)." >&2
        exit 1
      fi
    fi

    log "deleting all object versions and delete markers in $BUCKET"
    while :; do
      PAYLOAD=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" "${PROFILE_ARGS[@]}" \
        --max-items 1000 --output json | python3 -c "
import json, sys
d = json.load(sys.stdin)
objs = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in d.get('Versions', [])]
objs += [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in d.get('DeleteMarkers', [])]
print(json.dumps({'Objects': objs, 'Quiet': True}) if objs else '')
")
      [ -z "$PAYLOAD" ] && break
      aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" "${PROFILE_ARGS[@]}" \
        --delete "$PAYLOAD" >/dev/null
    done

    aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" "${PROFILE_ARGS[@]}"
    log "media bucket $BUCKET purged and deleted"
  fi
fi

# This deleted the CloudFront distribution. If a CNAME for its media
# subdomain still exists in the root account's zone, CloudFront's
# domain-fronting protection will REFUSE to create the next distribution's
# alias — it does a live DNS lookup and rejects aliases that currently
# resolve to a different distribution. This bites every recreate cycle
# after DNS has been wired up once; it's a no-op the very first time.
MEDIA_SUBDOMAIN=$(python3 -c "
import json
env = json.load(open('$REPO_ROOT/environments.json')).get('$ENV_LABEL', {})
print(env.get('mediaSubdomain', 'cfmedia-$ENV_LABEL'))
")
APEX_DOMAIN="geek.dev"   # keep in sync with APEX_DOMAIN in bin/web_infrastructure.ts
log "ACTION REQUIRED before the next deploy:"
log "  Delete the CNAME for $MEDIA_SUBDOMAIN.$APEX_DOMAIN in the root account's"
log "  $APEX_DOMAIN hosted zone. It points at the distribution just deleted —"
log "  left in place, it will cause the next 'cdk deploy' to fail with:"
log "    CREATE_FAILED ... AWS::CloudFront::Distribution ... incorrectly"
log "    configured DNS record that points to another CloudFront distribution"
log "  Recreate the CNAME (pointed at the NEW MediaDistributionDomain output)"
log "  only after the next deploy succeeds. See docs/destroy-and-restart.md."
