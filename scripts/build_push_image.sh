#!/usr/bin/env bash
set -euo pipefail

# Build and push the app image to ECR.
# Usage:
#   AWS_ACCOUNT_ID=<id> AWS_REGION=us-east-1 ENV_NAME=dev IMAGE_TAG=latest bash scripts/build_push_image.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENV_NAME="${ENV_NAME:-dev}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REPO_PREFIX="${REPO_PREFIX:-mood-app}"
PLATFORM="${PLATFORM:-linux/amd64}"

if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  echo "Set AWS_ACCOUNT_ID before running"
  exit 1
fi

REPO_NAME="${REPO_PREFIX}-${ENV_NAME}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_URI="${ECR_REGISTRY}/${REPO_NAME}"

aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

if docker buildx version >/dev/null 2>&1; then
  docker buildx build \
    --platform "${PLATFORM}" \
    -t mood-app:"${IMAGE_TAG}" \
    "${APP_DIR}" \
    --load
else
  docker build \
    --platform "${PLATFORM}" \
    -t mood-app:"${IMAGE_TAG}" \
    "${APP_DIR}"
fi

docker tag mood-app:"${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo "Pushed image: ${ECR_URI}:${IMAGE_TAG} (${PLATFORM})"
