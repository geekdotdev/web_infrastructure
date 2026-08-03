#!/usr/bin/env bash
# MVP deployment pipeline for one environment.
#
# Usage: deployment/deploy.sh <env> [aws-profile] [extra cdk args...]
#   e.g. deployment/deploy.sh dev
#        deployment/deploy.sh prod prod-admin
#        deployment/deploy.sh qa qa --require-approval never
#
# Phases run in order; each is a function so future stages (artifact push,
# smoke tests, DNS checks) slot in without restructuring.
#
# Bash version gate and profile resolution live in lib/common.sh, shared
# with destroy.sh — see that file for the compatibility note and the
# rationale for never falling back to the default credential chain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUTS_DIR="$REPO_ROOT/deployment/outputs"

ENV_LABEL="${1:?usage: deploy.sh <env> [aws-profile] [extra cdk args...]}"
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

# --- Phase 1: preflight ------------------------------------------------------
preflight() {
  log "preflight"
  cd "$REPO_ROOT"

  [ -f environments.json ] || {
    echo "environments.json missing — copy environments.json.example and fill it in" >&2
    exit 1
  }
  python3 -c "import json,sys; sys.exit(0 if '$ENV_LABEL' in json.load(open('environments.json')) else 1)" || {
    echo "env '$ENV_LABEL' not found in environments.json" >&2
    exit 1
  }
  [ -f "keys/${ENV_LABEL}-public.pem" ] || {
    echo "keys/${ENV_LABEL}-public.pem missing — see README 'CloudFront signing keys'" >&2
    exit 1
  }
  [ -d node_modules ] || { log "installing dependencies"; npm install --no-audit --no-fund; }

  log "type-check"
  npx tsc --noEmit
}

# --- Phase 2: synth ----------------------------------------------------------
synth() {
  log "synth"
  npx cdk synth --quiet -c "env=$ENV_LABEL" "${PROFILE_ARGS[@]}"
}

# --- Phase 3: deploy ---------------------------------------------------------
deploy() {
  log "deploy GhostLightsailStack-$ENV_LABEL"
  mkdir -p "$OUTPUTS_DIR"
  npx cdk deploy -c "env=$ENV_LABEL" \
    --outputs-file "$OUTPUTS_DIR/$ENV_LABEL.json" \
    "${PROFILE_ARGS[@]}" "${EXTRA_ARGS[@]}"
  log "stack created/updated at $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u '+%H:%M:%S UTC'))"
}

# --- Phase 4: push private artifacts -----------------------------------------
# Config pipeline stage 2 (source -> PUSH -> pull -> consume): stage required
# artifacts from local sources and upload them to the deployment bucket with
# an ephemeral Lightsail bucket access key (created, used, deleted). The
# instance's first boot blocks until these files land.
push_artifacts() {
  log "push private artifacts"
  local bucket="geek-dot-dev-deployment-resources-$ENV_LABEL"
  local region
  region=$(python3 -c "
import json
print(json.load(open('$REPO_ROOT/environments.json')).get('$ENV_LABEL', {}).get('region', 'us-east-1'))
")

  local stage_dir
  stage_dir=$(mktemp -d)

  # mysql.env from environments.json (required by the instance boot).
  python3 - "$ENV_LABEL" "$stage_dir" <<'PY'
import json, os, sys
env, stage = sys.argv[1], sys.argv[2]
pw = json.load(open('environments.json'))[env].get('mysqlRootPassword')
if not pw:
    sys.exit(f"mysqlRootPassword missing for env '{env}' in environments.json")
path = os.path.join(stage, 'mysql.env')
with open(path, 'w') as f:
    f.write(f"MYSQL_ROOT_PASSWORD={pw}\n")
os.chmod(path, 0o600)
PY

  # Optional extra private artifacts: private-config/<env>/ (gitignored).
  if [ -d "$REPO_ROOT/private-config/$ENV_LABEL" ]; then
    cp -R "$REPO_ROOT/private-config/$ENV_LABEL/." "$stage_dir/"
  fi

  log "minting ephemeral access key for $bucket"
  local key_json akid secret
  key_json=$(aws lightsail create-bucket-access-key --bucket-name "$bucket" \
    --region "$region" "${PROFILE_ARGS[@]}" --output json)
  akid=$(echo "$key_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["accessKey"]["accessKeyId"])')
  secret=$(echo "$key_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["accessKey"]["secretAccessKey"])')

  local pushed=0
  for i in 1 2 3 4 5 6; do  # new keys can take a few seconds to propagate
    if AWS_ACCESS_KEY_ID="$akid" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="" \
       aws s3 sync "$stage_dir" "s3://$bucket/" --region "$region"; then
      pushed=1
      break
    fi
    sleep 5
  done

  aws lightsail delete-bucket-access-key --bucket-name "$bucket" \
    --access-key-id "$akid" --region "$region" "${PROFILE_ARGS[@]}" || \
    log "WARNING: failed to delete ephemeral access key $akid — delete it manually"
  rm -rf "$stage_dir"

  [ "$pushed" = "1" ] || { echo "ERROR: artifact push to $bucket failed" >&2; exit 1; }
  log "artifacts pushed to $bucket"
}

# --- Phase 5: post-deploy ----------------------------------------------------
# Future pipeline stages land here: verify DNS/TLS, smoke-test the journal.
post_deploy() {
  log "post-deploy"
  if [ -f "$OUTPUTS_DIR/$ENV_LABEL.json" ]; then
    log "stack outputs written to deployment/outputs/$ENV_LABEL.json:"
    python3 -m json.tool "$OUTPUTS_DIR/$ENV_LABEL.json"
  fi
}

preflight
synth
deploy
push_artifacts
post_deploy
log "done"
