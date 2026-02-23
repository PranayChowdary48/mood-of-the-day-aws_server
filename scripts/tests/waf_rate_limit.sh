#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"
REQUESTS="${REQUESTS:-300}"
CONCURRENCY="${CONCURRENCY:-20}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/waf_rate_limit.sh <alb-dns> [env]"
  exit 1
fi

echo "Sending ${REQUESTS} requests (parallel=${CONCURRENCY}) to trigger WAF"
for i in $(seq 1 "${REQUESTS}"); do
  (curl -s -o /dev/null -w "%{http_code}\n" "http://${ALB_DNS}/" &) 
  if (( i % CONCURRENCY == 0 )); then
    wait
  fi
done
wait

END_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_TIME="$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)"

WEB_ACL_NAME="mood-${ENV_NAME}-webacl"

BLOCKED=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name BlockedRequests \
  --dimensions Name=WebACL,Value="${WEB_ACL_NAME}" Name=Rule,Value=ALL Name=Region,Value="${AWS_REGION}" \
  --start-time "${START_TIME}" \
  --end-time "${END_TIME}" \
  --period 60 \
  --statistics Sum \
  --query 'sum(Datapoints[].Sum)' \
  --output text)

if [[ "${BLOCKED}" == "None" ]]; then
  BLOCKED="0"
fi

echo "WAF BlockedRequests (last 15m): ${BLOCKED}"

python3 - <<'PY' "${BLOCKED}"
import sys
blocked = float(sys.argv[1])
if blocked <= 0:
    print("No blocked requests observed. Increase REQUESTS or verify WAF association.")
    sys.exit(1)
print("WAF proof check passed: blocked requests observed.")
PY
