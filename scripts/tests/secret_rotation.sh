#!/usr/bin/env bash
set -euo pipefail

ALB_DNS="${1:-}"
ENV_NAME="${2:-dev}"

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

HTTP_CODE=$(curl -s -o /tmp/mood_rotation_refresh.json -w "%{http_code}" \
  -u "${REFRESH_USER}:${REFRESH_PASSWORD}" \
  -X POST "http://${ALB_DNS}/refresh")

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "202" ]]; then
  echo "Refresh call failed after rotation (status=${HTTP_CODE})"
  cat /tmp/mood_rotation_refresh.json || true
  exit 1
fi

echo "Secret rotation check passed (status=${HTTP_CODE})"
