#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/efs_shared.sh <lb-dns>"
  exit 1
fi

TOKEN="efs-$(date +%s)-$RANDOM"

WRITE_RESP=$(curl -sS -X POST "http://${ALB_DNS}/api/shared/write?file=probe.txt" \
  -H 'Content-Type: application/json' \
  -d "{\"content\":\"${TOKEN}\"}")

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
  READ_RESP=$(curl -sS "http://${ALB_DNS}/api/shared/read?file=probe.txt")
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
