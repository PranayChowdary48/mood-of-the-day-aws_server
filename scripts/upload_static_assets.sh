#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="${ROOT_DIR}/static-site"

if [[ ! -d "${STATIC_DIR}" ]]; then
  echo "Static directory missing: ${STATIC_DIR}"
  exit 1
fi

BUCKET=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-StaticBucketName'].Value | [0]" \
  --output text)

if [[ -z "${BUCKET}" || "${BUCKET}" == "None" ]]; then
  echo "Static bucket export not found. Deploy cloudfront/static module first."
  exit 1
fi

DIST_ID=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-CloudFrontDistributionId'].Value | [0]" \
  --output text)

echo "Uploading static assets to s3://${BUCKET}"
aws s3 sync "${STATIC_DIR}/" "s3://${BUCKET}" --delete

if [[ -n "${DIST_ID}" && "${DIST_ID}" != "None" ]]; then
  echo "Creating CloudFront invalidation for distribution ${DIST_ID}"
  aws cloudfront create-invalidation --distribution-id "${DIST_ID}" --paths "/*" >/dev/null
fi

echo "Static upload complete"
