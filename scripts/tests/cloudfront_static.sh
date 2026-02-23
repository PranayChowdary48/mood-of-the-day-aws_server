#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"

CF_DOMAIN=$(aws cloudformation list-exports   --query "Exports[?Name=='Mood-${ENV_NAME}-CloudFrontDomainName'].Value | [0]"   --output text)

if [[ -z "${CF_DOMAIN}" || "${CF_DOMAIN}" == "None" ]]; then
  echo "CloudFront export not found. Deploy with ENABLE_CLOUDFRONT=true first."
  exit 1
fi

echo "CloudFront domain: ${CF_DOMAIN}"

API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/api/health")
if [[ "${API_STATUS}" != "200" ]]; then
  echo "Expected /api/health via CloudFront to return 200, got ${API_STATUS}"
  exit 1
fi

echo "CloudFront API routing check passed"

STATIC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/")
echo "CloudFront static root status: ${STATIC_STATUS}"
