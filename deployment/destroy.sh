#!/usr/bin/env bash
# Destroy one environment's stack — same strict profile resolution as
# deploy.sh (see lib/common.sh). Calling `cdk destroy` directly bypasses
# that resolution entirely: profile is a CDK CLI concept the app cannot
# supply, so a bare `cdk destroy -c env=X` falls through to whatever
# default credentials your shell happens to have. This wrapper exists so
# destroy can't silently target the wrong account any more than deploy can.
#
# Usage: deployment/destroy.sh <env> [aws-profile] [extra cdk args...]
#   e.g. deployment/destroy.sh dev
#        deployment/destroy.sh prod prod-admin
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_LABEL="${1:?usage: destroy.sh <env> [aws-profile] [extra cdk args...]}"
shift
PROFILE="${1:-}"
if [ -n "$PROFILE" ] && [[ "$PROFILE" != --* ]]; then
  shift
else
  PROFILE=""
fi
EXTRA_ARGS=("$@")

# shellcheck source=./lib/common.sh
source "$REPO_ROOT/deployment/lib/common.sh"
resolve_profile

log "WARNING: this deletes the instance, both data disks, the static IP,"
log "and the deployment bucket for '$ENV_LABEL'. See docs/destroy-and-restart.md."
log "destroying GhostLightsailStack-$ENV_LABEL via profile '$PROFILE'"

cd "$REPO_ROOT"
npx cdk destroy -c "env=$ENV_LABEL" "${PROFILE_ARGS[@]}" "${EXTRA_ARGS[@]}"
log "destroyed at $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u '+%H:%M:%S UTC'))"
