#!/usr/bin/env bash
set -euo pipefail

# Print useful outputs across v1 stacks.
# Usage: ./outputs.sh [env]
ENV_NAME="${1:-dev}"
BASE="mood-${ENV_NAME}"

print_outputs() {
  local stack="$1"
  echo "=== ${stack} ==="
  aws cloudformation describe-stacks \
    --stack-name "${stack}" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table || true
}

print_outputs "${BASE}-network"
print_outputs "${BASE}-registry"
print_outputs "${BASE}-config"
print_outputs "${BASE}-compute"
print_outputs "${BASE}-observability"
