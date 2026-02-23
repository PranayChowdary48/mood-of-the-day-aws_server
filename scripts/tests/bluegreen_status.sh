#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
GROUP_NAME="mood-${ENV_NAME}-bluegreen"
APP_NAME="mood-${ENV_NAME}-codedeploy"

echo "Checking CodeDeploy blue/green resources"
aws deploy get-deployment-group \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${GROUP_NAME}" \
  --query 'deploymentGroupInfo.[deploymentGroupName,deploymentStyle]' \
  --output table
