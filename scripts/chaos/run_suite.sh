#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
LB_DNS="${2:-}"

bash "$(dirname "$0")/kill_task.sh" "${ENV_NAME}"
bash "$(dirname "$0")/terminate_instance.sh" "${ENV_NAME}"
bash "$(dirname "$0")/cache_outage.sh" "${ENV_NAME}" "${LB_DNS}"

echo "[chaos] full suite completed for env=${ENV_NAME}"
