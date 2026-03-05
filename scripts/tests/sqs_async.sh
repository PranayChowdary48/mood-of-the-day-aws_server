#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"
REFRESH_USER="${REFRESH_USER:-}"
REFRESH_PASSWORD="${REFRESH_PASSWORD:-}"
AUTH_COOKIE="${AUTH_COOKIE:-}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/sqs_async.sh <lb-dns> [env]"
  exit 1
fi

if [[ -z "${REFRESH_USER}" || -z "${REFRESH_PASSWORD}" ]]; then
  SECRET_ARN=$(aws cloudformation list-exports \
    --query "Exports[?Name=='Mood-${ENV_NAME}-RefreshAuthSecretArn'].Value | [0]" \
    --output text)

  if [[ -n "${SECRET_ARN}" && "${SECRET_ARN}" != "None" ]]; then
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "${SECRET_ARN}" --query SecretString --output text)
    CREDS=$(python3 - <<'PY' "${SECRET_JSON}"
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get('refresh_user', ''))
print(obj.get('refresh_password', ''))
PY
)
    REFRESH_USER=$(echo "${CREDS}" | sed -n '1p')
    REFRESH_PASSWORD=$(echo "${CREDS}" | sed -n '2p')
  fi
fi

# Fallback for SSM backend or non-rotated setups
REFRESH_USER="${REFRESH_USER:-mood}"
REFRESH_PASSWORD="${REFRESH_PASSWORD:-mood}"

if [[ -n "${AUTH_COOKIE}" ]]; then
  STATUS=$(curl -s --max-time 15 -o /tmp/mood_sqs_resp.txt -w "%{http_code}" \
    -H "Cookie: ${AUTH_COOKIE}" \
    -X POST "http://${ALB_DNS}/api/refresh")
elif [[ -n "${COGNITO_ID_TOKEN:-}" ]]; then
  STATUS=$(curl -s --max-time 15 -o /tmp/mood_sqs_resp.txt -w "%{http_code}" \
    -H "Authorization: Bearer ${COGNITO_ID_TOKEN}" \
    -X POST "http://${ALB_DNS}/api/refresh")
else
  STATUS=$(curl -s --max-time 15 -o /tmp/mood_sqs_resp.txt -w "%{http_code}" \
    -u "${REFRESH_USER}:${REFRESH_PASSWORD}" \
    -X POST "http://${ALB_DNS}/api/refresh")
fi

if [[ "${STATUS}" == "302" || "${STATUS}" == "303" || "${STATUS}" == "307" ]]; then
  echo "ALB auth is enabled; /api/refresh redirected to Cognito."
  echo "To test async queue end-to-end, provide AUTH_COOKIE from an authenticated browser session."
  exit 0
fi

if [[ "${STATUS}" != "202" ]]; then
  echo "Expected HTTP 202 from async refresh, got ${STATUS}"
  cat /tmp/mood_sqs_resp.txt || true
  exit 1
fi

echo "Async refresh accepted (202)"

QUEUE_URL=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-QueueUrl'].Value | [0]" \
  --output text)

if [[ -z "${QUEUE_URL}" || "${QUEUE_URL}" == "None" ]]; then
  echo "Queue export not found. Deploy with ENABLE_SQS=true first."
  exit 1
fi

aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --output table
