#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
DR_REGION="${2:-}"
MODE="${3:-free-tier}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -z "${DR_REGION}" ]]; then
  echo "Usage: bash scripts/dr/run_dr_drill.sh <env> <dr-region> [mode]"
  exit 1
fi

echo "[dr] Step 1: copy RDS snapshot to ${DR_REGION}"
bash "${ROOT_DIR}/scripts/dr/copy_rds_snapshot.sh" "${ENV_NAME}" "${DR_REGION}"

echo "[dr] Step 2: deploy pilot-light stack in ${DR_REGION}"
bash "${ROOT_DIR}/scripts/dr/deploy_pilot_light.sh" "${ENV_NAME}" "${DR_REGION}" "${MODE}"

echo "[dr] Step 3: optional failover"
echo "Run manually when ready:"
echo "  HOSTED_ZONE_ID=<zone-id> DOMAIN_NAME=moodoftheday.fun SUBDOMAIN=${ENV_NAME} bash scripts/dr/failover_route53.sh ${ENV_NAME} ${DR_REGION}"

echo "[dr] Drill completed"
