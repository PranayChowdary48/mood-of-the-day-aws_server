#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
DR_REGION="${2:-}"
PRIMARY_REGION="${PRIMARY_REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}}"

if [[ -z "${DR_REGION}" ]]; then
  echo "Usage: bash scripts/dr/copy_rds_snapshot.sh <env> <dr-region>"
  exit 1
fi

DB_ID="mood-${ENV_NAME}-postgres"
SNAPSHOT_ID="${DB_ID}-snapshot-$(date +%Y%m%d%H%M%S)"
COPY_ID="${SNAPSHOT_ID}-copy-${DR_REGION}"

echo "Creating RDS snapshot ${SNAPSHOT_ID} in ${PRIMARY_REGION}"
aws rds create-db-snapshot \
  --region "${PRIMARY_REGION}" \
  --db-instance-identifier "${DB_ID}" \
  --db-snapshot-identifier "${SNAPSHOT_ID}" >/dev/null

aws rds wait db-snapshot-available \
  --region "${PRIMARY_REGION}" \
  --db-snapshot-identifier "${SNAPSHOT_ID}"

echo "Copying snapshot to ${DR_REGION} as ${COPY_ID}"
aws rds copy-db-snapshot \
  --source-region "${PRIMARY_REGION}" \
  --region "${DR_REGION}" \
  --source-db-snapshot-identifier "arn:aws:rds:${PRIMARY_REGION}:$(aws sts get-caller-identity --query Account --output text):snapshot:${SNAPSHOT_ID}" \
  --target-db-snapshot-identifier "${COPY_ID}" >/dev/null

aws rds wait db-snapshot-available \
  --region "${DR_REGION}" \
  --db-snapshot-identifier "${COPY_ID}"

echo "Snapshot copy complete: ${COPY_ID}"
