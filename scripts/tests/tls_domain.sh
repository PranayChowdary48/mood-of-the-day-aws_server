#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
DOMAIN_OVERRIDE="${2:-}"

if [[ -n "${DOMAIN_OVERRIDE}" ]]; then
  DOMAIN="${DOMAIN_OVERRIDE}"
else
  DOMAIN=$(aws cloudformation list-exports \
    --query "Exports[?Name=='Mood-${ENV_NAME}-AppDomainName'].Value | [0]" \
    --output text)
fi

if [[ -z "${DOMAIN}" || "${DOMAIN}" == "None" ]]; then
  echo "App domain export not found. Deploy with ENABLE_TLS_DOMAIN=true first."
  exit 1
fi

echo "Testing HTTPS domain: ${DOMAIN}"

RESULT=$(curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result}" "https://${DOMAIN}/health")
HTTP_CODE=$(echo "${RESULT}" | awk '{print $1}')
SSL_VERIFY=$(echo "${RESULT}" | awk '{print $2}')

echo "HTTP=${HTTP_CODE} SSL_VERIFY=${SSL_VERIFY}"

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Expected 200 from /health"
  exit 1
fi

if [[ "${SSL_VERIFY}" != "0" ]]; then
  echo "TLS certificate verification failed"
  exit 1
fi

echo "TLS domain check passed"
