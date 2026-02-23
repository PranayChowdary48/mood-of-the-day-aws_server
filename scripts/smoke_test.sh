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

echo "Home page check"
curl -fsS "http://${ALB_DNS}/" >/dev/null

echo "Smoke test passed"
