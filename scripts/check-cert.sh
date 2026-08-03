#!/usr/bin/env bash
# Check the TLS certificate served by a host: expiry dates, days remaining,
# and a nonzero exit if renewal is overdue (useful as a pipeline stage).
#
# Usage: scripts/check-cert.sh <fqdn> [warn-days]
#   e.g. scripts/check-cert.sh www.geek.dev
#        scripts/check-cert.sh cfmedia-prod.geek.dev 30
#
# Exit codes: 0 = ok, 1 = expires within warn-days (default 21), 2 = no cert.
set -euo pipefail

FQDN="${1:?usage: check-cert.sh <fqdn> [warn-days]}"
WARN_DAYS="${2:-21}"

# Resolve via a public resolver (bypassing the local machine's/ISP's DNS
# cache) so this reflects the record as the internet currently sees it, not
# a stale cached answer — the two failure modes DNS updates are prone to.
# Falls back to the system resolver if direct queries to 1.1.1.1 are blocked
# (some networks/firewalls block outbound port 53 to arbitrary resolvers).
# dig can print low-level diagnostics ("network unreachable") to stdout even
# with +short, so filter ';;'-prefixed lines rather than trusting emptiness
# or exit code alone.
resolve_dns() {
  local fqdn="$1" server="$2"
  # `|| true`: under set -eo pipefail, grep -v legitimately exiting 1 (zero
  # lines survived the filter — the normal case for an unresolvable name)
  # would otherwise kill the whole script before it can report that.
  if [ -n "$server" ]; then
    dig +short "@$server" "$fqdn" 2>/dev/null | grep -v '^;;' || true
  else
    dig +short "$fqdn" 2>/dev/null | grep -v '^;;' || true
  fi
}

if command -v dig >/dev/null 2>&1; then
  RESOLVED=$(resolve_dns "$FQDN" "1.1.1.1")
  [ -z "$RESOLVED" ] && RESOLVED=$(resolve_dns "$FQDN" "")
  if [ -n "$RESOLVED" ]; then
    echo "resolves to:"
    echo "$RESOLVED" | sed 's/^/  /'
  else
    echo "WARNING: $FQDN did not resolve to anything" >&2
  fi
else
  echo "WARNING: 'dig' not found — skipping DNS resolution check" >&2
fi
echo

CERT=$(echo | openssl s_client -connect "$FQDN:443" -servername "$FQDN" 2>/dev/null | \
  openssl x509 2>/dev/null) || { echo "ERROR: could not fetch a certificate from $FQDN:443" >&2; exit 2; }

echo "$CERT" | openssl x509 -noout -subject -issuer -dates

NOT_AFTER=$(echo "$CERT" | openssl x509 -noout -enddate | cut -d= -f2)
EXPIRY_EPOCH=$(date -j -f '%b %e %T %Y %Z' "$NOT_AFTER" +%s 2>/dev/null || date -d "$NOT_AFTER" +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - $(date +%s)) / 86400 ))

echo "days remaining: $DAYS_LEFT"

if [ "$DAYS_LEFT" -lt "$WARN_DAYS" ]; then
  echo "WARNING: cert for $FQDN expires in $DAYS_LEFT days (< $WARN_DAYS)." >&2
  echo "Auto-renewal (Caddy/ACM) should have replaced it by now — investigate." >&2
  exit 1
fi
