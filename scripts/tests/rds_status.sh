#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"

DB_ID="mood-${ENV_NAME}-postgres"

aws rds describe-db-instances   --db-instance-identifier "${DB_ID}"   --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,Endpoint.Address,Endpoint.Port]'   --output table
