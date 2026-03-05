#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
ASG_NAME="mood-${ENV_NAME}-compute-ContainerAsg"
CLUSTER_NAME=""
SERVICE_NAME=""

export_value() {
  local name="$1"
  aws cloudformation list-exports \
    --query "Exports[?Name=='${name}'].Value | [0]" \
    --output text
}

if aws cloudformation describe-stacks --stack-name "mood-${ENV_NAME}-compute" >/dev/null 2>&1; then
  ASG_NAME=$(aws cloudformation describe-stacks \
    --stack-name "mood-${ENV_NAME}-compute" \
    --query 'Stacks[0].Outputs[?OutputKey==`AsgName`].OutputValue' \
    --output text)
fi

if [[ -z "${ASG_NAME}" || "${ASG_NAME}" == "None" ]]; then
  echo "Unable to resolve ASG name"
  exit 1
fi

INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${ASG_NAME}" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "No instance found in ASG ${ASG_NAME}"
  exit 1
fi

echo "[chaos] terminating instance ${INSTANCE_ID} in ${ASG_NAME}"
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id "${INSTANCE_ID}" \
  --no-should-decrement-desired-capacity >/dev/null

echo "[chaos] waiting for ASG to recover desired in-service capacity"
for i in {1..30}; do
  desired=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${ASG_NAME}" \
    --query 'AutoScalingGroups[0].DesiredCapacity' --output text)

  in_service=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${ASG_NAME}" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' --output text)

  if [[ "${in_service}" != "None" && "${desired}" != "None" && ${in_service} -ge ${desired} ]]; then
    echo "[chaos] ASG recovered (in-service=${in_service}, desired=${desired})"
    break
  fi

  sleep 20
done

if [[ "${in_service:-None}" == "None" || "${desired:-None}" == "None" || ${in_service:-0} -lt ${desired:-1} ]]; then
  echo "[chaos] timeout waiting for ASG recovery"
  exit 1
fi

CLUSTER_NAME="$(export_value "Mood-${ENV_NAME}-ClusterName")"
SERVICE_NAME="$(export_value "Mood-${ENV_NAME}-ServiceName")"
if [[ -n "${CLUSTER_NAME}" && "${CLUSTER_NAME}" != "None" && -n "${SERVICE_NAME}" && "${SERVICE_NAME}" != "None" ]]; then
  echo "[chaos] waiting for ECS service to stabilize after instance replacement"
  aws ecs wait services-stable --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}"
fi

echo "[chaos] instance replacement assertions passed"
