#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"
REFRESH_USER="${REFRESH_USER:-mood}"
REFRESH_PASSWORD="${REFRESH_PASSWORD:-mood}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/sqs_async.sh <lb-dns> [env]"
  exit 1
fi

STATUS=$(curl -s -o /tmp/mood_sqs_resp.txt -w "%{http_code}" -u "${REFRESH_USER}:${REFRESH_PASSWORD}" -X POST "http://${ALB_DNS}/api/refresh")

if [[ "${STATUS}" != "202" ]]; then
  echo "Expected HTTP 202 from async refresh, got ${STATUS}"
  cat /tmp/mood_sqs_resp.txt || true
  exit 1
fi

echo "Async refresh accepted (202)"

QUEUE_URL=$(aws cloudformation list-exports   --query "Exports[?Name=='Mood-${ENV_NAME}-QueueUrl'].Value | [0]"   --output text)

if [[ -z "${QUEUE_URL}" || "${QUEUE_URL}" == "None" ]]; then
  echo "Queue export not found. Deploy with ENABLE_SQS=true first."
  exit 1
fi

aws sqs get-queue-attributes   --queue-url "${QUEUE_URL}"   --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible   --output table
