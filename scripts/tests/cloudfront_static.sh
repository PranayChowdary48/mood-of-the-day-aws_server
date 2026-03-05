#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"

CF_DOMAIN=$(aws cloudformation list-exports   --query "Exports[?Name=='Mood-${ENV_NAME}-CloudFrontDomainName'].Value | [0]"   --output text)

if [[ -z "${CF_DOMAIN}" || "${CF_DOMAIN}" == "None" ]]; then
  echo "CloudFront export not found. Deploy with ENABLE_CLOUDFRONT=true first."
  exit 1
fi

echo "CloudFront domain: ${CF_DOMAIN}"

API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/api/mood")
if [[ "${API_STATUS}" != "200" && "${API_STATUS}" != "302" && "${API_STATUS}" != "303" && "${API_STATUS}" != "307" ]]; then
  echo "Expected /api/mood via CloudFront to return 200 or redirect-to-login, got ${API_STATUS}"
  exit 1
fi

echo "CloudFront API routing check passed (/api/mood status=${API_STATUS})"

OAUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/oauth2/idpresponse")
if [[ "${OAUTH_STATUS}" == "404" ]]; then
  echo "Expected /oauth2/* to route to ALB for auth callback, got 404"
  exit 1
fi
echo "CloudFront OAuth callback routing check passed (/oauth2/idpresponse status=${OAUTH_STATUS})"

STATIC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/")
if [[ "${STATIC_STATUS}" != "200" ]]; then
  echo "Expected CloudFront static root to return 200, got ${STATIC_STATUS}"
  exit 1
fi

echo "CloudFront static root status: ${STATIC_STATUS}"
