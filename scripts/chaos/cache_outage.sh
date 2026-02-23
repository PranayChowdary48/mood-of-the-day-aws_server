#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
LB_DNS="${2:-}"
REFRESH_USER="${REFRESH_USER:-mood}"
REFRESH_PASSWORD="${REFRESH_PASSWORD:-mood}"

export_value() {
  local name="$1"
  aws cloudformation list-exports \
    --query "Exports[?Name=='${name}'].Value | [0]" \
    --output text
}

wait_for_health() {
  local timeout_secs="${1:-300}"
  local waited=0
  while (( waited < timeout_secs )); do
    if curl -fsS -m 5 "http://${LB_DNS}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
    waited=$(( waited + 10 ))
  done
  return 1
}

if [[ -z "${LB_DNS}" ]]; then
  LB_DNS="$(export_value "Mood-${ENV_NAME}-LoadBalancerDnsName")"
fi

if [[ -z "${LB_DNS}" || "${LB_DNS}" == "None" ]]; then
  echo "Unable to resolve load balancer DNS for env=${ENV_NAME}"
  exit 1
fi

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

  CACHE_CLUSTER_ID=$(aws elasticache describe-replication-groups \
    --replication-group-id "${RG_ID}" \
    --query 'ReplicationGroups[0].MemberClusters[0]' \
    --output text)

  if [[ -z "${CACHE_CLUSTER_ID}" || "${CACHE_CLUSTER_ID}" == "None" ]]; then
    echo "[chaos] could not resolve cache cluster id"
    exit 1
  fi

  aws elasticache reboot-cache-cluster --cache-cluster-id "${CACHE_CLUSTER_ID}" >/dev/null
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

echo "[chaos] verifying service recovered after cache outage simulation"
if ! wait_for_health 300; then
  echo "[chaos] /health did not recover to 200"
  exit 1
fi

HTTP_CODE=$(curl -s -o /tmp/mood_refresh_resp.txt -w "%{http_code}" -u "${REFRESH_USER}:${REFRESH_PASSWORD}" -X POST "http://${LB_DNS}/refresh")
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "[chaos] /refresh failed after recovery (status=${HTTP_CODE})"
  cat /tmp/mood_refresh_resp.txt || true
  exit 1
fi

echo "[chaos] cache outage recovery assertions passed"
