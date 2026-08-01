#!/usr/bin/env bash
# Request the CloudFront TLS cert for one environment's media domain.
#
# Usage: scripts/request-cert.sh <env> [aws-profile]
#   e.g. scripts/request-cert.sh dev dev
#
# Runs against the ENV account (cert must live where the distribution lives),
# always in us-east-1 (CloudFront requirement). Prints the DNS validation
# CNAME to paste into the geek.dev hosted zone in the root account, waits for
# issuance, then prints the ARN to put in environments.json.
set -euo pipefail

ENV_LABEL="${1:?usage: request-cert.sh <env> [aws-profile]}"
PROFILE_ARG=${2:+--profile $2}
APEX_DOMAIN="geek.dev"   # keep in sync with APEX_DOMAIN in bin/web_infrastructure.ts
DOMAIN="cfmedia-${ENV_LABEL}.${APEX_DOMAIN}"
REGION=us-east-1

echo "Requesting certificate for ${DOMAIN} (${REGION})..."
ARN=$(aws acm request-certificate \
  --domain-name "$DOMAIN" \
  --validation-method DNS \
  --region "$REGION" $PROFILE_ARG \
  --query CertificateArn --output text)
echo "Certificate ARN: $ARN"

echo "Waiting for ACM to generate the validation record..."
for i in $(seq 1 30); do
  RECORD=$(aws acm describe-certificate --certificate-arn "$ARN" \
    --region "$REGION" $PROFILE_ARG \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
    --output json 2>/dev/null || echo null)
  [ "$RECORD" != "null" ] && break
  sleep 5
done

echo
echo "Create this CNAME in the ${APEX_DOMAIN} hosted zone (root account):"
echo "$RECORD" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(f"  {r[\"Name\"]}  CNAME  {r[\"Value\"]}")'
echo
echo "Leave the record in place permanently — ACM uses it to auto-renew."
echo "Waiting for validation (ctrl-c is safe; issuance continues server-side)..."
aws acm wait certificate-validated --certificate-arn "$ARN" --region "$REGION" $PROFILE_ARG

echo
echo "Issued. Add to environments.json under \"${ENV_LABEL}\":"
echo "  \"mediaCertificateArn\": \"$ARN\""
echo "Then: npx cdk deploy -c env=${ENV_LABEL} ${2:+--profile $2}"
