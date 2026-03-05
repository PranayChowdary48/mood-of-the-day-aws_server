#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"
AUTH_COOKIE="${AUTH_COOKIE:-}"

if [[ -z "${ALB_DNS}" ]]; then
  echo "Usage: bash scripts/tests/secret_rotation.sh <lb-dns> [env]"
  exit 1
fi

SECRET_ARN=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-RefreshAuthSecretArn'].Value | [0]" \
  --output text)

if [[ -z "${SECRET_ARN}" || "${SECRET_ARN}" == "None" ]]; then
  echo "Refresh auth secret export not found. Deploy with SECRET_BACKEND=secretsmanager."
  exit 1
fi

get_current_version() {
  local arn="$1"
  local versions_json
  versions_json=$(aws secretsmanager describe-secret --secret-id "${arn}" --query 'VersionIdsToStages' --output json)
  python3 - <<'PY' "${versions_json}"
import json
import sys
versions = json.loads(sys.argv[1])
for vid, stages in versions.items():
    if 'AWSCURRENT' in stages:
        print(vid)
        break
PY
}

trigger_codedeploy_rollout() {
  local env_name="$1"
  local cluster_name="$2"
  local service_name="$3"
  local app_name deployment_group_name current_task_def request_json deployment_id

  app_name="${CODEDEPLOY_APP_NAME:-mood-${env_name}-codedeploy}"
  deployment_group_name="${CODEDEPLOY_DEPLOYMENT_GROUP_NAME:-mood-${env_name}-bluegreen}"

  current_task_def=$(aws ecs describe-services \
    --cluster "${cluster_name}" \
    --services "${service_name}" \
    --query 'services[0].taskDefinition' \
    --output text)

  if [[ -z "${current_task_def}" || "${current_task_def}" == "None" ]]; then
    echo "Unable to resolve current task definition for CodeDeploy rollout"
    exit 1
  fi

  request_json=$(mktemp)

  python3 - <<'PY' "${request_json}" "${current_task_def}" "${app_name}" "${deployment_group_name}"
import json
import sys

out_path, task_def_arn, app_name, dg_name = sys.argv[1:5]

appspec = {
    "version": 1,
    "Resources": [
        {
            "TargetService": {
                "Type": "AWS::ECS::Service",
                "Properties": {
                    "TaskDefinition": task_def_arn,
                    "LoadBalancerInfo": {
                        "ContainerName": "app",
                        "ContainerPort": 5000,
                    },
                },
            }
        }
    ],
}

payload = {
    "applicationName": app_name,
    "deploymentGroupName": dg_name,
    "deploymentConfigName": "CodeDeployDefault.ECSAllAtOnce",
    "revision": {
        "revisionType": "AppSpecContent",
        "appSpecContent": {
            "content": json.dumps(appspec),
        },
    },
}

json.dump(payload, open(out_path, 'w', encoding='utf-8'))
PY

  deployment_id=$(aws deploy create-deployment \
    --cli-input-json "file://${request_json}" \
    --query deploymentId \
    --output text)

  rm -f "${request_json}"

  echo "Triggered CodeDeploy deployment: ${deployment_id}"
  aws deploy wait deployment-successful --deployment-id "${deployment_id}"
  aws deploy get-deployment \
    --deployment-id "${deployment_id}" \
    --query 'deploymentInfo.{Status:status,CreateTime:createTime,CompleteTime:completeTime,Error:errorInformation.message}' \
    --output table
}

CURRENT_VERSION=$(get_current_version "${SECRET_ARN}")
echo "Current version before rotation: ${CURRENT_VERSION}"

aws secretsmanager rotate-secret --secret-id "${SECRET_ARN}" --rotate-immediately >/dev/null

echo "Waiting for AWSCURRENT version to change..."
NEW_VERSION="${CURRENT_VERSION}"
for _ in {1..36}; do
  NEW_VERSION=$(get_current_version "${SECRET_ARN}")
  if [[ "${NEW_VERSION}" != "${CURRENT_VERSION}" ]]; then
    break
  fi
  sleep 10
done

if [[ "${NEW_VERSION}" == "${CURRENT_VERSION}" ]]; then
  echo "Rotation did not advance AWSCURRENT within timeout"
  exit 1
fi

echo "Current version after rotation: ${NEW_VERSION}"

SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "${SECRET_ARN}" --query SecretString --output text)
CREDS=$(python3 - <<'PY' "${SECRET_JSON}"
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get('refresh_user', ''))
print(obj.get('refresh_password', ''))
PY
)
REFRESH_USER=$(echo "${CREDS}" | sed -n '1p')
REFRESH_PASSWORD=$(echo "${CREDS}" | sed -n '2p')

if [[ -z "${REFRESH_USER}" || -z "${REFRESH_PASSWORD}" ]]; then
  echo "Rotated secret is missing refresh credentials"
  exit 1
fi

CLUSTER_NAME=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-ClusterName'].Value | [0]" \
  --output text)
SERVICE_NAME=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-ServiceName'].Value | [0]" \
  --output text)

if [[ -n "${CLUSTER_NAME}" && "${CLUSTER_NAME}" != "None" && -n "${SERVICE_NAME}" && "${SERVICE_NAME}" != "None" ]]; then
  DEPLOY_CONTROLLER=$(aws ecs describe-services \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --query 'services[0].deploymentController.type' \
    --output text)

  if [[ "${DEPLOY_CONTROLLER}" == "CODE_DEPLOY" ]]; then
    echo "Service uses CODE_DEPLOY; triggering CodeDeploy deployment so tasks load AWSCURRENT secret..."
    trigger_codedeploy_rollout "${ENV_NAME}" "${CLUSTER_NAME}" "${SERVICE_NAME}"
  else
    echo "Forcing ECS service rollout so tasks load AWSCURRENT secret..."
    aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" --force-new-deployment >/dev/null
    aws ecs wait services-stable --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}"
  fi
fi

HTTP_CODE="000"
for _ in {1..18}; do
  if [[ -n "${AUTH_COOKIE}" ]]; then
    HTTP_CODE=$(curl -s --max-time 15 -o /tmp/mood_rotation_refresh.json -w "%{http_code}" \
      -H "Cookie: ${AUTH_COOKIE}" \
      -X POST "http://${ALB_DNS}/refresh")
  else
    HTTP_CODE=$(curl -s --max-time 15 -o /tmp/mood_rotation_refresh.json -w "%{http_code}" \
      -u "${REFRESH_USER}:${REFRESH_PASSWORD}" \
      -X POST "http://${ALB_DNS}/refresh")
  fi

  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "202" ]]; then
    break
  fi
  if [[ "${HTTP_CODE}" == "302" || "${HTTP_CODE}" == "303" || "${HTTP_CODE}" == "307" ]]; then
    break
  fi
  sleep 10
done

if [[ "${HTTP_CODE}" == "302" || "${HTTP_CODE}" == "303" || "${HTTP_CODE}" == "307" ]]; then
  echo "Secret rotation succeeded, but refresh endpoint is protected by ALB Cognito auth."
  echo "Provide AUTH_COOKIE for a full refresh-path validation."
  exit 0
fi

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "202" ]]; then
  echo "Refresh call failed after rotation (status=${HTTP_CODE})"
  cat /tmp/mood_rotation_refresh.json || true
  exit 1
fi

echo "Secret rotation check passed (status=${HTTP_CODE})"
