#!/usr/bin/env bash
set -euo pipefail

# Validate each CloudFormation template with AWS API parser.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${ROOT_DIR}/templates"

validate_file() {
  local file="$1"
  echo "Validating ${file}"
  aws cloudformation validate-template --template-body "file://${file}" >/dev/null
}

while IFS= read -r file; do
  validate_file "$file"
done < <(find "${TEMPLATE_DIR}" -type f -name '*.yaml' | sort)

echo "All templates are valid."
