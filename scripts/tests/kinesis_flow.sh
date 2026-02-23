#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"

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

for _ in {1..5}; do
  curl -fsS "http://${ALB_DNS}/api/mood" >/dev/null
  sleep 1
done

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
