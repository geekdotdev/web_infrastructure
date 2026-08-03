#!/usr/bin/env bash
# Shared setup for deployment/*.sh: bash version gate + strict AWS profile
# resolution. Sourced, not executed — callers set ENV_LABEL and
# REMAINING_ARGS[0] (optional CLI profile) before sourcing this file.
#
# Bash compatibility: requires bash >= 4.4 (empty arrays under `set -u`).
# macOS /bin/bash (3.2.57, frozen since 2007) fails with an "unbound
# variable" error on empty array expansion — use Homebrew bash
# (`brew install bash`), which the `env bash` shebang picks up via PATH.

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "ERROR: bash >= 4.4 required; this is $BASH_VERSION." >&2
  echo "On macOS: brew install bash, then open a new shell (or run: /opt/homebrew/bin/bash $0 ...)." >&2
  exit 1
fi

log() { echo ">>> [$ENV_LABEL] $*"; }

# resolve_profile: sets PROFILE and PROFILE_ARGS from (in order) the CLI arg
# already in $PROFILE, or the env's "profile" attribute in environments.json.
# No fallback to the default credential chain — wrong-account accidents are
# the failure mode this pipeline exists to prevent. Every entry point
# (destroy.sh, ...) must call this before touching AWS, including
# calls made indirectly via `cdk` (profile is a CLI-level concept the CDK
# app itself cannot supply).
resolve_profile() {
  if [ -z "$PROFILE" ]; then
    if [ -f "$REPO_ROOT/environments.json" ]; then
      PROFILE=$(python3 -c "
import json
print(json.load(open('$REPO_ROOT/environments.json')).get('$ENV_LABEL', {}).get('profile', ''))
")
    fi
    if [ -n "$PROFILE" ]; then
      log "using profile from environments.json: $PROFILE"
    else
      echo "ERROR: no AWS profile for env '$ENV_LABEL'." >&2
      echo "Pass one as an argument, or add \"profile\" to the '$ENV_LABEL' entry in environments.json." >&2
      echo "Refusing to fall back to the default credential chain." >&2
      exit 1
    fi
  fi
  PROFILE_ARGS=(--profile "$PROFILE")

  if ! aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE"; then
    echo "ERROR: profile '$PROFILE' not found (checked ~/.aws/config and ~/.aws/credentials)." >&2
    exit 1
  fi
}
