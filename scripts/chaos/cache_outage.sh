#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
LB_DNS="${2:-}"
BASE_URL="${BASE_URL:-}"
REFRESH_USER="${REFRESH_USER:-mood}"
REFRESH_PASSWORD="${REFRESH_PASSWORD:-mood}"

export_value() {
  local name="$1"
  aws cloudformation list-exports \
    --query "Exports[?Name=='${name}'].Value | [0]" \
    --output text
}

load_refresh_creds() {
  local secret_arn secret_json creds
  secret_arn="$(export_value "Mood-${ENV_NAME}-RefreshAuthSecretArn")"
  if [[ -z "${secret_arn}" || "${secret_arn}" == "None" ]]; then
    return
  fi

  secret_json=$(aws secretsmanager get-secret-value --secret-id "${secret_arn}" --query SecretString --output text)
  creds=$(python3 - <<'PY' "${secret_json}"
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get("refresh_user", ""))
print(obj.get("refresh_password", ""))
PY
)

  REFRESH_USER="$(echo "${creds}" | sed -n '1p')"
  REFRESH_PASSWORD="$(echo "${creds}" | sed -n '2p')"
}

wait_for_health() {
  local timeout_secs="${1:-300}"
  local waited=0
  while (( waited < timeout_secs )); do
    local status
    status=$(curl -ksS -o /dev/null -w "%{http_code}" -m 5 "${BASE_URL}/health" || true)

    if [[ "${status}" == "200" ]]; then
      return 0
    fi

    if [[ "${status}" == "301" || "${status}" == "302" || "${status}" == "303" || "${status}" == "307" || "${status}" == "308" ]]; then
      local location redirect_base
      location=$(curl -ksSI -m 5 "${BASE_URL}/health" | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r' | head -n1)
      if [[ -n "${location}" ]]; then
        redirect_base=$(python3 - "${location}" <<'PY'
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1].strip())
if u.scheme and u.netloc:
    print(f"{u.scheme}://{u.netloc}")
PY
)
        if [[ -n "${redirect_base}" && "${redirect_base}" != "None" ]]; then
          BASE_URL="${redirect_base}"
        fi
      fi
    fi

    sleep 10
    waited=$(( waited + 10 ))
  done
  return 1
}

if [[ -z "${LB_DNS}" ]]; then
  LB_DNS="$(export_value "Mood-${ENV_NAME}-LoadBalancerDnsName")"
fi

CLUSTER="$(export_value "Mood-${ENV_NAME}-ClusterName")"
SERVICE="$(export_value "Mood-${ENV_NAME}-ServiceName")"

if [[ -z "${LB_DNS}" || "${LB_DNS}" == "None" ]]; then
  echo "Unable to resolve load balancer DNS for env=${ENV_NAME}"
  exit 1
fi

if [[ -z "${BASE_URL}" ]]; then
  if [[ "${LB_DNS}" == http://* || "${LB_DNS}" == https://* ]]; then
    BASE_URL="${LB_DNS}"
  else
    BASE_URL="http://${LB_DNS}"
  fi
fi
BASE_URL="${BASE_URL%/}"

echo "[chaos] using base URL ${BASE_URL}"

echo "[chaos] pre-check /health"
if ! wait_for_health 180; then
  echo "[chaos] baseline health check failed before cache outage test"
  exit 1
fi

if aws cloudformation describe-stacks --stack-name "mood-${ENV_NAME}-elasticache" >/dev/null 2>&1; then
  echo "[chaos] elasticache mode detected; rebooting one cache node"

  RG_ID=$(aws cloudformation describe-stack-resource \
    --stack-name "mood-${ENV_NAME}-elasticache" \
    --logical-resource-id RedisReplicationGroup \
    --query 'StackResourceDetail.PhysicalResourceId' \
    --output text)

  if [[ -z "${RG_ID}" || "${RG_ID}" == "None" ]]; then
    echo "[chaos] could not resolve replication group id"
    exit 1
  fi

  REPLICA_CLUSTER_ID=$(aws elasticache describe-replication-groups \
    --replication-group-id "${RG_ID}" \
    --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[?CurrentRole==`replica`] | [0].CacheClusterId' \
    --output text)

  if [[ -n "${REPLICA_CLUSTER_ID}" && "${REPLICA_CLUSTER_ID}" != "None" ]]; then
    CACHE_CLUSTER_ID="${REPLICA_CLUSTER_ID}"
    echo "[chaos] selected replica cluster ${CACHE_CLUSTER_ID} for reboot"
  else
    CACHE_CLUSTER_ID=$(aws elasticache describe-replication-groups \
      --replication-group-id "${RG_ID}" \
      --query 'ReplicationGroups[0].MemberClusters[0]' \
      --output text)
    echo "[chaos] no replica found; falling back to cluster ${CACHE_CLUSTER_ID}"
  fi

  if [[ -z "${CACHE_CLUSTER_ID}" || "${CACHE_CLUSTER_ID}" == "None" ]]; then
    echo "[chaos] could not resolve cache cluster id"
    exit 1
  fi

  CACHE_NODE_ID=$(aws elasticache describe-cache-clusters \
    --cache-cluster-id "${CACHE_CLUSTER_ID}" \
    --show-cache-node-info \
    --query 'CacheClusters[0].CacheNodes[0].CacheNodeId' \
    --output text)

  if [[ -z "${CACHE_NODE_ID}" || "${CACHE_NODE_ID}" == "None" ]]; then
    echo "[chaos] could not resolve cache node id"
    exit 1
  fi

  aws elasticache reboot-cache-cluster \
    --cache-cluster-id "${CACHE_CLUSTER_ID}" \
    --cache-node-ids-to-reboot "${CACHE_NODE_ID}" >/dev/null
  aws elasticache wait cache-cluster-available --cache-cluster-id "${CACHE_CLUSTER_ID}"
else
  echo "[chaos] sidecar redis mode detected; stopping one app task to simulate cache task loss"

  CLUSTER="$(export_value "Mood-${ENV_NAME}-ClusterName")"
  SERVICE="$(export_value "Mood-${ENV_NAME}-ServiceName")"

  if [[ -z "${CLUSTER}" || "${CLUSTER}" == "None" || -z "${SERVICE}" || "${SERVICE}" == "None" ]]; then
    echo "[chaos] could not resolve cluster/service exports"
    exit 1
  fi

  TASK_ARN=$(aws ecs list-tasks \
    --cluster "${CLUSTER}" \
    --service-name "${SERVICE}" \
    --desired-status RUNNING \
    --query 'taskArns[0]' \
    --output text)

  if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
    echo "[chaos] no running task found"
    exit 1
  fi

  aws ecs stop-task --cluster "${CLUSTER}" --task "${TASK_ARN}" --reason "chaos-test:cache-outage-simulation" >/dev/null
  aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"
fi

load_refresh_creds

echo "[chaos] verifying service recovered after cache outage simulation"
if [[ -n "${CLUSTER}" && "${CLUSTER}" != "None" && -n "${SERVICE}" && "${SERVICE}" != "None" ]]; then
  echo "[chaos] waiting for ECS service stable state before ALB health checks"
  aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}" || true
fi

if ! wait_for_health 300; then
  echo "[chaos] /health did not recover to 200"
  echo "[chaos] diagnostic: /health response"
  curl -kisS -m 10 "${BASE_URL}/health" || true
  echo "[chaos] diagnostic: /live response"
  curl -kisS -m 10 "${BASE_URL}/live" || true
  if [[ -n "${CLUSTER}" && "${CLUSTER}" != "None" && -n "${SERVICE}" && "${SERVICE}" != "None" ]]; then
    echo "[chaos] diagnostic: ECS service state"
    aws ecs describe-services \
      --cluster "${CLUSTER}" \
      --services "${SERVICE}" \
      --query 'services[0].[desiredCount,runningCount,pendingCount,events[0:5].[createdAt,message]]' \
      --output json || true
  fi
  TG_ARN="$(export_value "Mood-${ENV_NAME}-AlbTargetGroupArn")"
  if [[ -n "${TG_ARN}" && "${TG_ARN}" != "None" ]]; then
    echo "[chaos] diagnostic: target group health"
    aws elbv2 describe-target-health \
      --target-group-arn "${TG_ARN}" \
      --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' \
      --output json || true
  fi
  if [[ -n "${RG_ID:-}" ]]; then
    echo "[chaos] diagnostic: replication group status"
    aws elasticache describe-replication-groups \
      --replication-group-id "${RG_ID}" \
      --query 'ReplicationGroups[0].[Status,NodeGroups[0].NodeGroupMembers[*].[CacheClusterId,CurrentRole,CacheNodeId]]' \
      --output json || true
  fi
  exit 1
fi

if [[ -n "${AUTH_COOKIE:-}" ]]; then
  HTTP_CODE=$(curl -ks -o /tmp/mood_refresh_resp.txt -w "%{http_code}" -H "Cookie: ${AUTH_COOKIE}" -X POST "${BASE_URL}/refresh")
elif [[ -n "${COGNITO_ID_TOKEN:-}" ]]; then
  HTTP_CODE=$(curl -ks -o /tmp/mood_refresh_resp.txt -w "%{http_code}" -H "Authorization: Bearer ${COGNITO_ID_TOKEN}" -X POST "${BASE_URL}/refresh")
else
  HTTP_CODE=$(curl -ks -o /tmp/mood_refresh_resp.txt -w "%{http_code}" -u "${REFRESH_USER}:${REFRESH_PASSWORD}" -X POST "${BASE_URL}/refresh")
fi
if [[ "${HTTP_CODE}" == "301" || "${HTTP_CODE}" == "302" || "${HTTP_CODE}" == "303" || "${HTTP_CODE}" == "307" || "${HTTP_CODE}" == "308" ]]; then
  echo "[chaos] /refresh is protected by auth or HTTPS redirect (status=${HTTP_CODE})"
  echo "[chaos] cache outage recovery assertions passed (health recovered)"
  exit 0
fi
if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "202" ]]; then
  echo "[chaos] /refresh failed after recovery (status=${HTTP_CODE})"
  cat /tmp/mood_refresh_resp.txt || true
  exit 1
fi

echo "[chaos] cache outage recovery assertions passed (refresh_status=${HTTP_CODE})"
