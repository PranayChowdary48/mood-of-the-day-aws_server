#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
AUTH_COOKIE="${AUTH_COOKIE:-}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/efs_shared.sh <lb-dns>"
  exit 1
fi

TOKEN="efs-$(date +%s)-$RANDOM"

if [[ -n "${AUTH_COOKIE}" ]]; then
  WRITE_STATUS=$(curl -sS -o /tmp/mood_efs_write.json -w "%{http_code}" -X POST "http://${ALB_DNS}/api/shared/write?file=probe.txt" \
    -H "Cookie: ${AUTH_COOKIE}" \
    -H 'Content-Type: application/json' \
    -d "{\"content\":\"${TOKEN}\"}")
else
  WRITE_STATUS=$(curl -sS -o /tmp/mood_efs_write.json -w "%{http_code}" -X POST "http://${ALB_DNS}/api/shared/write?file=probe.txt" \
    -H 'Content-Type: application/json' \
    -d "{\"content\":\"${TOKEN}\"}")
fi

if [[ "${WRITE_STATUS}" == "302" || "${WRITE_STATUS}" == "303" || "${WRITE_STATUS}" == "307" ]]; then
  echo "ALB auth is enabled; /api/shared/write redirected to Cognito."
  echo "Provide AUTH_COOKIE from an authenticated browser session to run EFS test."
  exit 0
fi

if [[ "${WRITE_STATUS}" != "200" ]]; then
  echo "Expected /api/shared/write status 200, got ${WRITE_STATUS}"
  cat /tmp/mood_efs_write.json || true
  exit 1
fi

WRITE_RESP=$(cat /tmp/mood_efs_write.json)
echo "Write response: ${WRITE_RESP}"

python3 - <<'PY' "${WRITE_RESP}" "${TOKEN}"
import json
import sys
resp = json.loads(sys.argv[1])
expected = sys.argv[2]
if resp.get('content') != expected:
    raise SystemExit('Write verification failed')
PY

HOSTS=()
for _ in {1..8}; do
  if [[ -n "${AUTH_COOKIE}" ]]; then
    READ_RESP=$(curl -sS -H "Cookie: ${AUTH_COOKIE}" "http://${ALB_DNS}/api/shared/read?file=probe.txt")
  else
    READ_RESP=$(curl -sS "http://${ALB_DNS}/api/shared/read?file=probe.txt")
  fi
  echo "Read response: ${READ_RESP}"
  python3 - <<'PY' "${READ_RESP}" "${TOKEN}"
import json
import sys
resp = json.loads(sys.argv[1])
expected = sys.argv[2]
if resp.get('content') != expected:
    raise SystemExit('Read verification failed')
print(resp.get('hostname',''))
PY
  HOSTS+=("$(python3 - <<'PY' "${READ_RESP}"
import json,sys
print(json.loads(sys.argv[1]).get('hostname',''))
PY
)")
  sleep 1
done

UNIQUE_COUNT=$(printf "%s\n" "${HOSTS[@]}" | awk 'NF' | sort -u | wc -l | tr -d ' ')
echo "Observed hosts for shared file read: ${UNIQUE_COUNT}"

echo "EFS shared read/write check passed"
