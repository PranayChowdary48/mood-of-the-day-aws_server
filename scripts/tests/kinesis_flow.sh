#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"
AUTH_COOKIE="${AUTH_COOKIE:-}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/kinesis_flow.sh <lb-dns> [env]"
  exit 1
fi

STREAM_NAME=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-KinesisStreamName'].Value | [0]" \
  --output text)

if [[ -z "${STREAM_NAME}" || "${STREAM_NAME}" == "None" ]]; then
  echo "Kinesis stream export not found. Deploy with ENABLE_KINESIS=true first."
  exit 1
fi

echo "Using stream: ${STREAM_NAME}"

REDIRECT_SEEN="false"
for _ in {1..5}; do
  if [[ -n "${AUTH_COOKIE}" ]]; then
    STATUS=$(curl -sS -o /tmp/mood_kinesis_probe.json -w "%{http_code}" -H "Cookie: ${AUTH_COOKIE}" "http://${ALB_DNS}/api/mood")
  else
    STATUS=$(curl -sS -o /tmp/mood_kinesis_probe.json -w "%{http_code}" "http://${ALB_DNS}/api/mood")
  fi
  if [[ "${STATUS}" == "302" || "${STATUS}" == "303" || "${STATUS}" == "307" ]]; then
    REDIRECT_SEEN="true"
    break
  fi
  if [[ "${STATUS}" != "200" ]]; then
    echo "Unexpected /api/mood status: ${STATUS}"
    cat /tmp/mood_kinesis_probe.json || true
    exit 1
  fi
  sleep 1
done

if [[ "${REDIRECT_SEEN}" == "true" ]]; then
  echo "ALB auth is enabled; /api/mood redirected to Cognito."
  echo "Provide AUTH_COOKIE from an authenticated browser session to validate Kinesis ingestion."
  exit 0
fi

END_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_TIME="$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)"

INCOMING=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value="${STREAM_NAME}" \
  --start-time "${START_TIME}" \
  --end-time "${END_TIME}" \
  --period 60 \
  --statistics Sum \
  --query 'sum(Datapoints[].Sum)' \
  --output text)

if [[ "${INCOMING}" == "None" ]]; then
  INCOMING="0"
fi

echo "Kinesis IncomingRecords (last 15m): ${INCOMING}"

python3 - <<'PY' "${INCOMING}"
import sys
value = float(sys.argv[1])
if value <= 0:
    raise SystemExit('No Kinesis records observed from app traffic')
print('Kinesis flow check passed')
PY
