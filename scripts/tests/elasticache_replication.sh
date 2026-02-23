#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
STACK_NAME="mood-${ENV_NAME}-elasticache"

RG_ID=$(aws cloudformation describe-stack-resource \
  --stack-name "${STACK_NAME}" \
  --logical-resource-id RedisReplicationGroup \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)

if [[ -z "${RG_ID}" || "${RG_ID}" == "None" ]]; then
  echo "ElastiCache stack/resource not found"
  exit 1
fi

aws elasticache describe-replication-groups \
  --replication-group-id "${RG_ID}" \
  --query 'ReplicationGroups[0].[Status,MemberClusters,NodeGroups]' \
  --output json
