#!/usr/bin/env bash
set -euo pipefail

# Deploy CloudFormation stacks in dependency order.
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
ENABLE_CLOUDFRONT_FRONTDOOR="${ENABLE_CLOUDFRONT_FRONTDOOR:-false}"
CLOUDFRONT_CERT_ARN="${CLOUDFRONT_CERT_ARN:-}"
ALB_CERT_ARN="${ALB_CERT_ARN:-}"
API_SUBDOMAIN_LABEL="${API_SUBDOMAIN_LABEL:-api}"
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
ENABLE_COGNITO="${ENABLE_COGNITO:-false}"
ASSET_BASE_URL="${ASSET_BASE_URL:-}"
COGNITO_DOMAIN_PREFIX="${COGNITO_DOMAIN_PREFIX:-}"
COGNITO_CALLBACK_URL="${COGNITO_CALLBACK_URL:-}"
COGNITO_LOGOUT_URL="${COGNITO_LOGOUT_URL:-}"
DOMAIN_NAME="${DOMAIN_NAME:-moodoftheday.fun}"
SUBDOMAIN="${SUBDOMAIN:-${ENV_NAME}}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
FORCE_COMPUTE_UPDATE_ON_CODE_DEPLOY="${FORCE_COMPUTE_UPDATE_ON_CODE_DEPLOY:-false}"

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

if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" && "${ENABLE_CLOUDFRONT}" != "true" ]]; then
  echo "ENABLE_CLOUDFRONT_FRONTDOOR=true requires ENABLE_CLOUDFRONT=true"
  exit 1
fi

if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" && "${ENABLE_TLS_DOMAIN}" != "true" ]]; then
  echo "ENABLE_CLOUDFRONT_FRONTDOOR=true requires ENABLE_TLS_DOMAIN=true"
  exit 1
fi

if [[ "${ENABLE_COGNITO}" == "true" && "${ENABLE_TLS_DOMAIN}" != "true" ]]; then
  echo "ENABLE_COGNITO=true requires ENABLE_TLS_DOMAIN=true (ALB authenticate-cognito needs HTTPS listener)."
  exit 1
fi

resolve_hosted_zone_id() {
  local domain="$1"
  aws route53 list-hosted-zones-by-name \
    --dns-name "${domain}." \
    --query "HostedZones[?Name=='${domain}.']|[0].Id" \
    --output text 2>/dev/null | sed 's|/hostedzone/||'
}

resolve_export_value() {
  local export_name="$1"
  aws cloudformation list-exports \
    --query "Exports[?Name=='${export_name}'].Value | [0]" \
    --output text 2>/dev/null
}

resolve_account_id() {
  aws sts get-caller-identity --query 'Account' --output text 2>/dev/null
}

resolve_stack_param() {
  local stack_name="$1"
  local key="$2"
  aws cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --query "Stacks[0].Parameters[?ParameterKey=='${key}'].ParameterValue | [0]" \
    --output text 2>/dev/null
}

stack_exists() {
  local stack_name="$1"
  aws cloudformation describe-stacks --stack-name "${stack_name}" >/dev/null 2>&1
}

resolve_us_east_1_cert_arn() {
  local fqdn="$1"
  aws acm list-certificates \
    --region us-east-1 \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='${fqdn}' || contains(SubjectAlternativeNameSummaries, '${fqdn}')].CertificateArn | [0]" \
    --output text 2>/dev/null
}

resolve_regional_cert_arn() {
  local fqdn="$1"
  aws acm list-certificates \
    --region "${AWS_REGION:-$(aws configure get region 2>/dev/null || echo ap-northeast-1)}" \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='${fqdn}' || contains(SubjectAlternativeNameSummaries, '${fqdn}')].CertificateArn | [0]" \
    --output text 2>/dev/null
}

validate_https_url() {
  local name="$1"
  local url="$2"
  if ! python3 - "$name" "$url" <<'PY'
import sys
from urllib.parse import urlparse

label = sys.argv[1]
value = sys.argv[2]
parsed = urlparse(value)
if parsed.scheme != "https" or not parsed.netloc:
    print(f"{label} must be a full https URL with a host (got: {value})")
    raise SystemExit(1)
PY
  then
    exit 1
  fi
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

if [[ -n "${SUBDOMAIN}" ]]; then
  APP_FQDN="${SUBDOMAIN}.${DOMAIN_NAME}"
  API_FQDN="${API_SUBDOMAIN_LABEL}.${SUBDOMAIN}.${DOMAIN_NAME}"
else
  APP_FQDN="${DOMAIN_NAME}"
  API_FQDN="${API_SUBDOMAIN_LABEL}.${DOMAIN_NAME}"
fi

if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" && -z "${CLOUDFRONT_CERT_ARN}" ]]; then
  RESOLVED_CF_CERT="$(resolve_us_east_1_cert_arn "${APP_FQDN}")"
  if [[ -n "${RESOLVED_CF_CERT}" && "${RESOLVED_CF_CERT}" != "None" ]]; then
    CLOUDFRONT_CERT_ARN="${RESOLVED_CF_CERT}"
  else
    echo "ENABLE_CLOUDFRONT_FRONTDOOR=true requires CLOUDFRONT_CERT_ARN (us-east-1 ACM cert for ${APP_FQDN})."
    exit 1
  fi
fi

if [[ "${ENABLE_COGNITO}" == "true" && "${DEPLOYMENT_STRATEGY}" == "bluegreen" && "${LOAD_BALANCER_TYPE}" == "alb" && -z "${ALB_CERT_ARN}" ]]; then
  ALB_CERT_ARN="$(resolve_export_value "Mood-${ENV_NAME}-CertificateArn")"
  if [[ -z "${ALB_CERT_ARN}" || "${ALB_CERT_ARN}" == "None" ]]; then
    ALB_CERT_ARN="$(resolve_regional_cert_arn "${APP_FQDN}")"
  fi

  if [[ -z "${ALB_CERT_ARN}" || "${ALB_CERT_ARN}" == "None" ]]; then
    echo "bluegreen + Cognito requires ALB_CERT_ARN (regional ACM cert for ${APP_FQDN})."
    exit 1
  fi
fi

if [[ -z "${ASSET_BASE_URL}" ]]; then
  if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" ]]; then
    ASSET_BASE_URL="https://${APP_FQDN}"
  elif [[ "${ENABLE_CLOUDFRONT}" == "true" ]]; then
    CF_ASSET_DOMAIN="$(resolve_export_value "Mood-${ENV_NAME}-CloudFrontDomainName")"
    if [[ -n "${CF_ASSET_DOMAIN}" && "${CF_ASSET_DOMAIN}" != "None" ]]; then
      ASSET_BASE_URL="https://${CF_ASSET_DOMAIN}"
    fi
  fi
fi

network_overrides="$(kv_overrides "${PARAM_FILE}" EnvName VpcCidr PublicSubnet1Cidr PublicSubnet2Cidr PrivateSubnet1Cidr PrivateSubnet2Cidr) EnableVpcEndpoints=${ENABLE_VPC_ENDPOINTS} EnableNatGateway=${ENABLE_NAT_GATEWAY}"
registry_overrides="$(kv_overrides "${PARAM_FILE}" EnvName)"
config_overrides="$(kv_overrides "${PARAM_FILE}" EnvName RefreshUser RefreshPassword) SecretBackend=${SECRET_BACKEND}"
compute_overrides="$(kv_overrides "${PARAM_FILE}" EnvName ClusterBaseName AppImageTag InstanceType AsgMinSize AsgDesiredCapacity AsgMaxSize ServiceDesiredCount ServiceMinCount ServiceMaxCount) TaskSubnetType=${TASK_SUBNET_TYPE} SecretBackend=${SECRET_BACKEND} CacheBackend=${CACHE_BACKEND} LoadBalancerType=${LOAD_BALANCER_TYPE} DeploymentStrategy=${DEPLOYMENT_STRATEGY} EnableAsyncQueue=${ENABLE_SQS} EnableRds=${ENABLE_RDS} EnableEfs=${ENABLE_EFS} EnableKinesis=${ENABLE_KINESIS} EnableCognitoAuth=${ENABLE_COGNITO} AlbCertificateArn=${ALB_CERT_ARN} AssetBaseUrl=${ASSET_BASE_URL}"
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

if [[ "${ENABLE_COGNITO}" == "true" ]]; then
  if [[ -z "${COGNITO_DOMAIN_PREFIX}" ]]; then
    EXISTING_PREFIX="$(resolve_stack_param "${base}-cognito" "CognitoDomainPrefix")"
    if [[ -n "${EXISTING_PREFIX}" && "${EXISTING_PREFIX}" != "None" ]]; then
      COGNITO_DOMAIN_PREFIX="${EXISTING_PREFIX}"
    else
      ACCOUNT_ID="$(resolve_account_id)"
      COGNITO_DOMAIN_PREFIX="mood-${ENV_NAME}-${ACCOUNT_ID}"
    fi
  fi

  if [[ -z "${COGNITO_CALLBACK_URL}" ]]; then
    if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" ]]; then
      COGNITO_CALLBACK_URL="https://${APP_FQDN}/oauth2/idpresponse"
    else
      CF_DOMAIN="$(resolve_export_value "Mood-${ENV_NAME}-CloudFrontDomainName")"
      if [[ -n "${CF_DOMAIN}" && "${CF_DOMAIN}" != "None" ]]; then
        COGNITO_CALLBACK_URL="https://${CF_DOMAIN}/oauth2/idpresponse"
      elif [[ "${ENABLE_TLS_DOMAIN}" == "true" ]]; then
        COGNITO_CALLBACK_URL="https://${APP_FQDN}/oauth2/idpresponse"
      else
        echo "ENABLE_COGNITO=true requires COGNITO_CALLBACK_URL, or an existing CloudFront/domain output."
        exit 1
      fi
    fi
  fi

  if [[ -z "${COGNITO_LOGOUT_URL}" ]]; then
    COGNITO_LOGOUT_URL="$(python3 - "${COGNITO_CALLBACK_URL}" <<'PY'
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
print(f"{u.scheme}://{u.netloc}/")
PY
)"
  fi

  validate_https_url "COGNITO_CALLBACK_URL" "${COGNITO_CALLBACK_URL}"
  validate_https_url "COGNITO_LOGOUT_URL" "${COGNITO_LOGOUT_URL}"

  deploy_stack "${base}-cognito" "${TEMPLATE_DIR}/optional/cognito.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName) CognitoDomainPrefix=${COGNITO_DOMAIN_PREFIX} CallbackUrl=${COGNITO_CALLBACK_URL} LogoutUrl=${COGNITO_LOGOUT_URL}"
fi

deploy_compute_stack="true"
if [[ "${DEPLOYMENT_STRATEGY}" == "bluegreen" && "${FORCE_COMPUTE_UPDATE_ON_CODE_DEPLOY}" != "true" ]]; then
  if stack_exists "${base}-compute"; then
    existing_cluster="$(resolve_export_value "Mood-${ENV_NAME}-ClusterName")"
    existing_service="$(resolve_export_value "Mood-${ENV_NAME}-ServiceName")"

    if [[ -n "${existing_cluster}" && "${existing_cluster}" != "None" && -n "${existing_service}" && "${existing_service}" != "None" ]]; then
      existing_controller=$(aws ecs describe-services         --cluster "${existing_cluster}"         --services "${existing_service}"         --query 'services[0].deploymentController.type'         --output text 2>/dev/null || true)

      if [[ "${existing_controller}" == "CODE_DEPLOY" ]]; then
        deploy_compute_stack="false"
        echo "Skipping ${base}-compute update: service uses CODE_DEPLOY; use make bluegreen-release for app task updates."
      fi
    fi
  fi
fi

if [[ "${deploy_compute_stack}" == "true" ]]; then
  deploy_stack "${base}-compute" "${TEMPLATE_DIR}/04-ecs-ec2-alb.yaml" "${compute_overrides}"
fi

deploy_stack "${base}-observability" "${TEMPLATE_DIR}/05-observability.yaml" "${obs_overrides}"

if [[ "${ENABLE_TLS_DOMAIN}" == "true" ]]; then
  if [[ -z "${HOSTED_ZONE_ID}" ]]; then
    HOSTED_ZONE_ID="$(resolve_hosted_zone_id "${DOMAIN_NAME}")"
  fi
  if [[ -z "${HOSTED_ZONE_ID}" || "${HOSTED_ZONE_ID}" == "None" ]]; then
    echo "Could not resolve HOSTED_ZONE_ID for domain ${DOMAIN_NAME}. Set HOSTED_ZONE_ID explicitly."
    exit 1
  fi

  domain_primary_alias="true"
  domain_api_alias="false"
  if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" ]]; then
    domain_primary_alias="false"
    domain_api_alias="true"
  fi

  deploy_stack "${base}-domain" "${TEMPLATE_DIR}/optional/route53-acm.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName) DomainName=${DOMAIN_NAME} HostedZoneId=${HOSTED_ZONE_ID} Subdomain=${SUBDOMAIN} EnableCognitoAuth=${ENABLE_COGNITO} DeploymentStrategy=${DEPLOYMENT_STRATEGY} CreatePrimaryAliasToAlb=${domain_primary_alias} CreateApiAliasToAlb=${domain_api_alias} ApiSubdomainLabel=${API_SUBDOMAIN_LABEL}"
fi

if [[ "${MODE}" == "showcase" ]]; then
  if [[ "${ENABLE_WAF}" == "true" && "${LOAD_BALANCER_TYPE}" == "alb" ]]; then
    deploy_stack "${base}-waf" "${TEMPLATE_DIR}/optional/waf.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)"
  fi

  if [[ "${ENABLE_CLOUDFRONT}" == "true" && "${LOAD_BALANCER_TYPE}" == "alb" ]]; then
    api_origin_override=""
    alias_overrides=""

    if [[ "${ENABLE_CLOUDFRONT_FRONTDOOR}" == "true" ]]; then
      alias_overrides=" AliasDomainName=${APP_FQDN} ViewerCertificateArn=${CLOUDFRONT_CERT_ARN} HostedZoneId=${HOSTED_ZONE_ID}"

      if [[ "${DEPLOYMENT_STRATEGY}" == "bluegreen" && "${ENABLE_COGNITO}" != "true" ]]; then
        echo "CloudFront API origin: using ALB DNS for blue/green deployments without Cognito."
      else
        api_origin_override=" ApiOriginDomainName=${API_FQDN}"
      fi
    elif [[ "${ENABLE_TLS_DOMAIN}" == "true" ]]; then
      if [[ "${DEPLOYMENT_STRATEGY}" == "bluegreen" && "${ENABLE_COGNITO}" != "true" ]]; then
        echo "CloudFront API origin: using ALB DNS for blue/green deployments without Cognito."
      else
        api_origin_override=" ApiOriginDomainName=${APP_FQDN}"
      fi
    fi

    deploy_stack "${base}-cloudfront" "${TEMPLATE_DIR}/optional/cloudfront.yaml" "$(kv_overrides "${PARAM_FILE}" EnvName)${api_origin_override}${alias_overrides}"
  fi
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
echo "  cloudfront_frontdoor=${ENABLE_CLOUDFRONT_FRONTDOOR}"
echo "  tls_domain=${ENABLE_TLS_DOMAIN}"
echo "  secret_rotation=${ENABLE_SECRET_ROTATION}"
echo "  cognito=${ENABLE_COGNITO}"
echo "  asset_base_url=${ASSET_BASE_URL}"
