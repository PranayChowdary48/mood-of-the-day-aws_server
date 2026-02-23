#!/usr/bin/env bash
set -euo pipefail

# Deploy v1 stacks in dependency order.
# Usage: ./deploy.sh [env] [mode]
#   env: dev|prod
#   mode: free-tier|showcase
ENV_NAME="${1:-dev}"
MODE="${2:-free-tier}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${ROOT_DIR}/templates"
PARAM_FILE="${ROOT_DIR}/params/${ENV_NAME}.json"

if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "Missing parameter file: ${PARAM_FILE}"
  exit 1
fi

if [[ "${MODE}" == "showcase" ]]; then
  default_endpoints="true"
  default_task_subnet="private"
else
  default_endpoints="false"
  default_task_subnet="public"
fi

ENABLE_VPC_ENDPOINTS="${ENABLE_VPC_ENDPOINTS:-${default_endpoints}}"
TASK_SUBNET_TYPE="${TASK_SUBNET_TYPE:-${default_task_subnet}}"
LOAD_BALANCER_TYPE="${LOAD_BALANCER_TYPE:-alb}"
SECRET_BACKEND="${SECRET_BACKEND:-ssm}"
CACHE_BACKEND="${CACHE_BACKEND:-sidecar}"
DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY:-rolling}"

NETWORK_PROFILE="${NETWORK_PROFILE:-baseline}"
ENABLE_NAT_GATEWAY="${ENABLE_NAT_GATEWAY:-false}"

if [[ "${NETWORK_PROFILE}" == "strict-private" ]]; then
  TASK_SUBNET_TYPE="private"
  if [[ "${ENABLE_NAT_GATEWAY}" == "false" ]]; then
    ENABLE_NAT_GATEWAY="true"
  fi
fi

# Redis sidecar image is pulled from public ECR. Private tasks need NAT egress.
if [[ "${TASK_SUBNET_TYPE}" == "private" && "${CACHE_BACKEND}" == "sidecar" && "${ENABLE_NAT_GATEWAY}" == "false" ]]; then
  ENABLE_NAT_GATEWAY="true"
fi

ENABLE_WAF="${ENABLE_WAF:-false}"
ENABLE_CLOUDFRONT="${ENABLE_CLOUDFRONT:-false}"
ENABLE_ELASTICACHE="${ENABLE_ELASTICACHE:-false}"
ENABLE_SQS="${ENABLE_SQS:-false}"
ENABLE_RDS="${ENABLE_RDS:-false}"
ENABLE_ALERTS="${ENABLE_ALERTS:-false}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
ENABLE_EFS="${ENABLE_EFS:-false}"
ENABLE_KINESIS="${ENABLE_KINESIS:-false}"
ENABLE_TLS_DOMAIN="${ENABLE_TLS_DOMAIN:-false}"
ENABLE_SECRET_ROTATION="${ENABLE_SECRET_ROTATION:-false}"
ROTATION_DAYS="${ROTATION_DAYS:-7}"
DOMAIN_NAME="${DOMAIN_NAME:-moodoftheday.fun}"
SUBDOMAIN="${SUBDOMAIN:-${ENV_NAME}}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

if [[ "${DEPLOYMENT_STRATEGY}" == "bluegreen" && "${LOAD_BALANCER_TYPE}" != "alb" ]]; then
  echo "bluegreen deployment strategy is supported only with LOAD_BALANCER_TYPE=alb"
  exit 1
fi

if [[ "${CACHE_BACKEND}" == "elasticache" ]]; then
  ENABLE_ELASTICACHE="true"
fi

if [[ "${ENABLE_SECRET_ROTATION}" == "true" && "${SECRET_BACKEND}" != "secretsmanager" ]]; then
  echo "ENABLE_SECRET_ROTATION=true requires SECRET_BACKEND=secretsmanager"
  exit 1
fi

if [[ "${ENABLE_TLS_DOMAIN}" == "true" && "${LOAD_BALANCER_TYPE}" != "alb" ]]; then
  echo "ENABLE_TLS_DOMAIN=true requires LOAD_BALANCER_TYPE=alb"
  exit 1
fi

resolve_hosted_zone_id() {
  local domain="$1"
  aws route53 list-hosted-zones-by-name \
    --dns-name "${domain}." \
    --query "HostedZones[?Name=='${domain}.']|[0].Id" \
    --output text 2>/dev/null | sed 's|/hostedzone/||'
}

kv_overrides() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
keys = sys.argv[2:]
obj = json.load(open(path, "r", encoding="utf-8"))
parts = []
for k in keys:
    if k in obj:
        parts.append(f"{k}={obj[k]}")
print(" ".join(parts))
PY
}

deploy_stack() {
  local stack_name="$1"
  local template="$2"
  local overrides="$3"
  echo "Deploying ${stack_name}"
  # shellcheck disable=SC2086
  aws cloudformation deploy \
    --stack-name "${stack_name}" \
    --template-file "${template}" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides ${overrides}
}

base="mood-${ENV_NAME}"

network_overrides="$(kv_overrides "${PARAM_FILE}" EnvName VpcCidr PublicSubnet1Cidr PublicSubnet2Cidr PrivateSubnet1Cidr PrivateSubnet2Cidr) EnableVpcEndpoints=${ENABLE_VPC_ENDPOINTS} EnableNatGateway=${ENABLE_NAT_GATEWAY}"
registry_overrides="$(kv_overrides "${PARAM_FILE}" EnvName)"
config_overrides="$(kv_overrides "${PARAM_FILE}" EnvName RefreshUser RefreshPassword) SecretBackend=${SECRET_BACKEND}"
compute_overrides="$(kv_overrides "${PARAM_FILE}" EnvName ClusterBaseName AppImageTag InstanceType AsgMinSize AsgDesiredCapacity AsgMaxSize ServiceDesiredCount ServiceMinCount ServiceMaxCount) TaskSubnetType=${TASK_SUBNET_TYPE} SecretBackend=${SECRET_BACKEND} CacheBackend=${CACHE_BACKEND} LoadBalancerType=${LOAD_BALANCER_TYPE} DeploymentStrategy=${DEPLOYMENT_STRATEGY} EnableAsyncQueue=${ENABLE_SQS} EnableRds=${ENABLE_RDS} EnableEfs=${ENABLE_EFS} EnableKinesis=${ENABLE_KINESIS}"
obs_overrides="$(kv_overrides "${PARAM_FILE}" EnvName) LoadBalancerType=${LOAD_BALANCER_TYPE} EnableAlerts=${ENABLE_ALERTS}"

deploy_stack "${base}-network" "${TEMPLATE_DIR}/01-network.yaml" "${network_overrides}"
deploy_stack "${base}-registry" "${TEMPLATE_DIR}/02-ecr.yaml" "${registry_overrides}"
deploy_stack "${base}-config" "${TEMPLATE_DIR}/03-ssm.yaml" "${config_overrides}"

if [[ "${ENABLE_SECRET_ROTATION}" == "true" ]]; then
  deploy_stack "${base}-secret-rotation" "${TEMPLATE_DIR}/optional/secret-rotation.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName) AutomaticallyAfterDays=${ROTATION_DAYS}"
fi

if [[ "${ENABLE_ALERTS}" == "true" ]]; then
  alert_overrides="$(kv_overrides "${PARAM_FILE}" EnvName)"
  if [[ -n "${ALERT_EMAIL}" ]]; then
    alert_overrides="${alert_overrides} AlertEmail=${ALERT_EMAIL}"
  fi
  deploy_stack "${base}-alerts" "${TEMPLATE_DIR}/optional/alerts-sns.yaml" "${alert_overrides}"
fi

if [[ "${ENABLE_SQS}" == "true" ]]; then
  deploy_stack "${base}-sqs" "${TEMPLATE_DIR}/optional/sqs-async.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
fi

if [[ "${ENABLE_RDS}" == "true" ]]; then
  deploy_stack "${base}-rds" "${TEMPLATE_DIR}/optional/rds-postgres.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
fi

if [[ "${ENABLE_EFS}" == "true" ]]; then
  deploy_stack "${base}-efs" "${TEMPLATE_DIR}/optional/efs.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
fi

if [[ "${ENABLE_KINESIS}" == "true" ]]; then
  deploy_stack "${base}-kinesis" "${TEMPLATE_DIR}/optional/kinesis.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
fi

if [[ "${MODE}" == "showcase" && "${ENABLE_ELASTICACHE}" == "true" ]]; then
  deploy_stack "${base}-elasticache" "${TEMPLATE_DIR}/optional/elasticache.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
fi

deploy_stack "${base}-compute" "${TEMPLATE_DIR}/04-ecs-ec2-alb.yaml" "${compute_overrides}"
deploy_stack "${base}-observability" "${TEMPLATE_DIR}/05-observability.yaml" "${obs_overrides}"

if [[ "${MODE}" == "showcase" ]]; then
  if [[ "${ENABLE_WAF}" == "true" && "${LOAD_BALANCER_TYPE}" == "alb" ]]; then
    deploy_stack "${base}-waf" "${TEMPLATE_DIR}/optional/waf.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
  fi

  if [[ "${ENABLE_CLOUDFRONT}" == "true" && "${LOAD_BALANCER_TYPE}" == "alb" ]]; then
    deploy_stack "${base}-cloudfront" "${TEMPLATE_DIR}/optional/cloudfront.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
  fi
fi

if [[ "${ENABLE_TLS_DOMAIN}" == "true" ]]; then
  if [[ -z "${HOSTED_ZONE_ID}" ]]; then
    HOSTED_ZONE_ID="$(resolve_hosted_zone_id "${DOMAIN_NAME}")"
  fi
  if [[ -z "${HOSTED_ZONE_ID}" || "${HOSTED_ZONE_ID}" == "None" ]]; then
    echo "Could not resolve HOSTED_ZONE_ID for domain ${DOMAIN_NAME}. Set HOSTED_ZONE_ID explicitly."
    exit 1
  fi

  deploy_stack "${base}-domain" "${TEMPLATE_DIR}/optional/route53-acm.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName) DomainName=${DOMAIN_NAME} HostedZoneId=${HOSTED_ZONE_ID} Subdomain=${SUBDOMAIN}"
fi

echo "Deployment finished"
echo "  env=${ENV_NAME}"
echo "  mode=${MODE}"
echo "  lb_type=${LOAD_BALANCER_TYPE}"
echo "  deploy_strategy=${DEPLOYMENT_STRATEGY}"
echo "  task_subnet=${TASK_SUBNET_TYPE}"
echo "  secret_backend=${SECRET_BACKEND}"
echo "  cache_backend=${CACHE_BACKEND}"
echo "  endpoints=${ENABLE_VPC_ENDPOINTS}"
echo "  network_profile=${NETWORK_PROFILE}"
echo "  nat_gateway=${ENABLE_NAT_GATEWAY}"
echo "  sqs=${ENABLE_SQS}"
echo "  rds=${ENABLE_RDS}"
echo "  efs=${ENABLE_EFS}"
echo "  kinesis=${ENABLE_KINESIS}"
echo "  alerts=${ENABLE_ALERTS}"
echo "  cloudfront_static=${ENABLE_CLOUDFRONT}"
echo "  tls_domain=${ENABLE_TLS_DOMAIN}"
echo "  secret_rotation=${ENABLE_SECRET_ROTATION}"
