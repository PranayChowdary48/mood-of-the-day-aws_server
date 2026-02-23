#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
CLUSTER="mood-${ENV_NAME}"
SERVICE="mood-app-${ENV_NAME}"

echo "[chaos] stopping one task in service ${SERVICE}"
TASK_ARN=$(aws ecs list-tasks \
  --cluster "${CLUSTER}" \
  --service-name "${SERVICE}" \
  --desired-status RUNNING \
  --query 'taskArns[0]' --output text)

if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
  echo "No running task found"
  exit 1
fi

aws ecs stop-task --cluster "${CLUSTER}" --task "${TASK_ARN}" --reason "chaos-test:manual-stop" >/dev/null
aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"

echo "[chaos] service recovered after task stop"
