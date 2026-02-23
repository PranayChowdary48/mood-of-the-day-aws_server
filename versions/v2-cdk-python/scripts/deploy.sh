#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
MODE="${2:-free-tier}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  bash "${ROOT_DIR}/scripts/bootstrap.sh"
fi

append_ctx() {
  local key="$1"
  local value="${2:-}"
  if [[ -n "${value}" ]]; then
    CTX_ARGS+=(--context "${key}=${value}")
  fi
}

CTX_ARGS=(--context "env=${ENV_NAME}" --context "mode=${MODE}")
append_ctx "region" "${REGION:-}"
append_ctx "enableWaf" "${ENABLE_WAF:-}"
append_ctx "enableBlueGreen" "${ENABLE_BLUEGREEN:-}"
append_ctx "enableElastiCache" "${ENABLE_ELASTICACHE:-}"
append_ctx "enableCloudFront" "${ENABLE_CLOUDFRONT:-}"
append_ctx "enableVpcEndpoints" "${ENABLE_VPC_ENDPOINTS:-}"
append_ctx "taskSubnetType" "${TASK_SUBNET_TYPE:-}"
append_ctx "secretBackend" "${SECRET_BACKEND:-}"
append_ctx "cacheBackend" "${CACHE_BACKEND:-}"
append_ctx "loadBalancerType" "${LOAD_BALANCER_TYPE:-}"
append_ctx "deploymentStrategy" "${DEPLOYMENT_STRATEGY:-}"
append_ctx "networkProfile" "${NETWORK_PROFILE:-}"
append_ctx "enableSqs" "${ENABLE_SQS:-}"
append_ctx "enableRds" "${ENABLE_RDS:-}"
append_ctx "enableAlerts" "${ENABLE_ALERTS:-}"
append_ctx "alertEmail" "${ALERT_EMAIL:-}"
append_ctx "enableStaticSite" "${ENABLE_STATIC_SITE:-}"
append_ctx "enableEfs" "${ENABLE_EFS:-}"
append_ctx "enableKinesis" "${ENABLE_KINESIS:-}"
append_ctx "enableTlsDomain" "${ENABLE_TLS_DOMAIN:-}"
append_ctx "enableSecretRotation" "${ENABLE_SECRET_ROTATION:-}"
append_ctx "domainName" "${DOMAIN_NAME:-}"
append_ctx "hostedZoneId" "${HOSTED_ZONE_ID:-}"
append_ctx "subdomain" "${SUBDOMAIN:-}"

cd "${ROOT_DIR}"
PATH="${VENV_DIR}/bin:${PATH}" npx cdk deploy --require-approval never "${CTX_ARGS[@]}"
