#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
IMAGE_TAG="${2:-}"
WAIT_FOR_SUCCESS="${WAIT_FOR_SUCCESS:-true}"

if [[ -z "${IMAGE_TAG}" ]]; then
  echo "Usage: bash scripts/deploy/bluegreen_codedeploy.sh <env> <image-tag>"
  echo "Example: bash scripts/deploy/bluegreen_codedeploy.sh dev bg-release-001"
  exit 1
fi

export_value() {
  local name="$1"
  aws cloudformation list-exports \
    --query "Exports[?Name=='${name}'].Value | [0]" \
    --output text
}

CLUSTER_NAME="${CLUSTER_NAME:-$(export_value "Mood-${ENV_NAME}-ClusterName")}" 
SERVICE_NAME="${SERVICE_NAME:-$(export_value "Mood-${ENV_NAME}-ServiceName")}" 
REPO_URI="${REPO_URI:-$(export_value "Mood-${ENV_NAME}-RepositoryUri")}" 
APP_NAME="${APP_NAME:-mood-${ENV_NAME}-codedeploy}"
DEPLOYMENT_GROUP_NAME="${DEPLOYMENT_GROUP_NAME:-mood-${ENV_NAME}-bluegreen}"

if [[ -z "${CLUSTER_NAME}" || "${CLUSTER_NAME}" == "None" ]]; then
  echo "Missing cluster export: Mood-${ENV_NAME}-ClusterName"
  exit 1
fi

if [[ -z "${SERVICE_NAME}" || "${SERVICE_NAME}" == "None" ]]; then
  echo "Missing service export: Mood-${ENV_NAME}-ServiceName"
  exit 1
fi

if [[ -z "${REPO_URI}" || "${REPO_URI}" == "None" ]]; then
  echo "Missing repository export: Mood-${ENV_NAME}-RepositoryUri"
  exit 1
fi

CURRENT_TASK_DEF_ARN=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --query 'services[0].taskDefinition' \
  --output text)

if [[ -z "${CURRENT_TASK_DEF_ARN}" || "${CURRENT_TASK_DEF_ARN}" == "None" ]]; then
  echo "Unable to resolve current task definition from ECS service ${SERVICE_NAME}"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CURRENT_TD_JSON="${TMP_DIR}/current-task-def.json"
NEW_TD_REGISTER_JSON="${TMP_DIR}/new-task-def-register.json"
CODEDEPLOY_REQUEST_JSON="${TMP_DIR}/codedeploy-request.json"

aws ecs describe-task-definition \
  --task-definition "${CURRENT_TASK_DEF_ARN}" \
  --query taskDefinition \
  --output json > "${CURRENT_TD_JSON}"

python3 - <<'PY' "${CURRENT_TD_JSON}" "${NEW_TD_REGISTER_JSON}" "${REPO_URI}" "${IMAGE_TAG}"
import json
import sys

src, dst, repo_uri, image_tag = sys.argv[1:5]
obj = json.load(open(src, 'r', encoding='utf-8'))

for key in [
    'taskDefinitionArn',
    'revision',
    'status',
    'requiresAttributes',
    'compatibilities',
    'registeredAt',
    'registeredBy',
    'deregisteredAt',
    'inferenceAccelerators',
]:
    obj.pop(key, None)

updated = False
for container in obj.get('containerDefinitions', []):
    if container.get('name') == 'app':
        container['image'] = f"{repo_uri}:{image_tag}"
        updated = True

if not updated:
    raise SystemExit("Container named 'app' not found in task definition")

json.dump(obj, open(dst, 'w', encoding='utf-8'))
PY

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json "file://${NEW_TD_REGISTER_JSON}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

python3 - <<'PY' "${CODEDEPLOY_REQUEST_JSON}" "${NEW_TASK_DEF_ARN}" "${APP_NAME}" "${DEPLOYMENT_GROUP_NAME}"
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

DEPLOYMENT_ID=$(aws deploy create-deployment \
  --cli-input-json "file://${CODEDEPLOY_REQUEST_JSON}" \
  --query deploymentId \
  --output text)

echo "Created blue/green deployment"
echo "  env=${ENV_NAME}"
echo "  app=${APP_NAME}"
echo "  deployment-group=${DEPLOYMENT_GROUP_NAME}"
echo "  image=${REPO_URI}:${IMAGE_TAG}"
echo "  new-task-def=${NEW_TASK_DEF_ARN}"
echo "  deployment-id=${DEPLOYMENT_ID}"

if [[ "${WAIT_FOR_SUCCESS}" == "true" ]]; then
  echo "Waiting for deployment success..."
  aws deploy wait deployment-successful --deployment-id "${DEPLOYMENT_ID}"
  aws deploy get-deployment \
    --deployment-id "${DEPLOYMENT_ID}" \
    --query 'deploymentInfo.{Status:status,CreateTime:createTime,CompleteTime:completeTime,Error:errorInformation.message}' \
    --output table
else
  echo "Skipping wait (WAIT_FOR_SUCCESS=${WAIT_FOR_SUCCESS})."
fi
