#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"

VPC_ID=$(aws cloudformation list-exports   --query "Exports[?Name=='Mood-${ENV_NAME}-VpcId'].Value | [0]"   --output text)

if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "Unable to find exported VPC id for env=${ENV_NAME}. Deploy network stack first."
  exit 1
fi

echo "VPC: ${VPC_ID}"
aws ec2 describe-vpc-endpoints   --filters "Name=vpc-id,Values=${VPC_ID}"   --query 'VpcEndpoints[].{Id:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,State:State}'   --output table

COUNT=$(aws ec2 describe-vpc-endpoints   --filters "Name=vpc-id,Values=${VPC_ID}"   --query 'length(VpcEndpoints)'   --output text)

echo "Endpoint count: ${COUNT}"
if [[ "${COUNT}" == "0" ]]; then
  echo "No endpoints found. This is expected if endpoints were not enabled."
fi
