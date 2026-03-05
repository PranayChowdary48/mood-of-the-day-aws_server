#!/usr/bin/env bash
set -euo pipefail

# Basic runtime checks against ALB endpoint.
# Usage:
#   bash scripts/smoke_test.sh <alb-dns>

ALB_DNS="${1:-}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/smoke_test.sh <alb-dns>"
  exit 1
fi

echo "Health check"
curl -fsS "http://${ALB_DNS}/health" | cat

echo "API auth gate check"
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${ALB_DNS}/api/mood")
if [[ "${API_STATUS}" != "200" && "${API_STATUS}" != "302" && "${API_STATUS}" != "303" && "${API_STATUS}" != "307" ]]; then
  echo "Unexpected /api/mood status: ${API_STATUS}"
  exit 1
fi
echo "/api/mood status: ${API_STATUS}"

echo "Smoke test passed"
