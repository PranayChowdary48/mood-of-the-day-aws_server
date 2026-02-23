#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
DR_REGION="${2:-}"
MODE="${3:-free-tier}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -z "${DR_REGION}" ]]; then
  echo "Usage: bash scripts/dr/deploy_pilot_light.sh <env> <dr-region> [mode]"
  exit 1
fi

echo "Deploying pilot-light stack in ${DR_REGION} (env=${ENV_NAME}, mode=${MODE})"
AWS_REGION="${DR_REGION}" \
ENABLE_VPC_ENDPOINTS=true \
NETWORK_PROFILE=strict-private \
ENABLE_NAT_GATEWAY=true \
ENABLE_WAF=false \
ENABLE_CLOUDFRONT=false \
ENABLE_ELASTICACHE=false \
ENABLE_RDS=false \
ENABLE_EFS=false \
ENABLE_KINESIS=false \
ENABLE_SQS=false \
ENABLE_ALERTS=false \
ENABLE_TLS_DOMAIN=false \
bash "${ROOT_DIR}/versions/v1-cloudformation/scripts/deploy.sh" "${ENV_NAME}" "${MODE}"

echo "Pilot-light deployment completed in ${DR_REGION}"
