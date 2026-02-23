#!/usr/bin/env bash
set -euo pipefail

# Destroy v1 stacks in reverse dependency order.
# Usage: ./destroy.sh [env]
ENV_NAME="${1:-dev}"

stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}

delete_stack_if_exists() {
  local stack="$1"
  if stack_exists "$stack"; then
    echo "Deleting ${stack}"
    aws cloudformation delete-stack --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --stack-name "$stack"
    echo "Deleted ${stack}"
  else
    echo "Skip ${stack} (not found)"
  fi
}

base="mood-${ENV_NAME}"

delete_stack_if_exists "${base}-domain"
delete_stack_if_exists "${base}-cloudfront"
delete_stack_if_exists "${base}-waf"
delete_stack_if_exists "${base}-observability"
delete_stack_if_exists "${base}-compute"
delete_stack_if_exists "${base}-elasticache"
delete_stack_if_exists "${base}-kinesis"
delete_stack_if_exists "${base}-efs"
delete_stack_if_exists "${base}-rds"
delete_stack_if_exists "${base}-sqs"
delete_stack_if_exists "${base}-alerts"
delete_stack_if_exists "${base}-secret-rotation"
delete_stack_if_exists "${base}-config"
delete_stack_if_exists "${base}-registry"
delete_stack_if_exists "${base}-network"
