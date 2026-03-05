#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
GROUP_NAME="mood-${ENV_NAME}-bluegreen"
APP_NAME="mood-${ENV_NAME}-codedeploy"

echo "Checking CodeDeploy blue/green resources"
aws deploy get-deployment-group \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${GROUP_NAME}" \
  --query 'deploymentGroupInfo.{Application:applicationName,DeploymentGroup:deploymentGroupName,DeploymentType:deploymentStyle.deploymentType,DeploymentOption:deploymentStyle.deploymentOption}' \
  --output table

DEPLOY_ID=$(aws deploy list-deployments \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${GROUP_NAME}" \
  --query 'deployments[0]' \
  --output text)

if [[ -z "${DEPLOY_ID}" || "${DEPLOY_ID}" == "None" ]]; then
  echo "No deployments found yet for ${APP_NAME}/${GROUP_NAME}."
  exit 0
fi

echo "Latest deployment: ${DEPLOY_ID}"
aws deploy get-deployment \
  --deployment-id "${DEPLOY_ID}" \
  --query 'deploymentInfo.{Status:status,CreateTime:createTime,CompleteTime:completeTime,Error:errorInformation.message}' \
  --output table
