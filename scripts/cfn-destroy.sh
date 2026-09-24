#!/usr/bin/env bash

set -euo pipefail

if [[ "${CONFIRM_DESTROY:-}" != "DESTROY" ]]; then
  echo "Refusing to destroy infrastructure. Set CONFIRM_DESTROY=DESTROY to continue." >&2
  exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "aws CLI is required" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARAMETERS_FILE="$SCRIPT_DIR/../parameters.yaml"
ENVIRONMENT_NAME="$(yq -r '.environment.name' "$PARAMETERS_FILE")"
REGION="$(yq -r '.environment.region' "$PARAMETERS_FILE")"

deleted_stacks=()

delete_stack() {
  local stack_name="$1"

  if ! aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$stack_name" >/dev/null 2>&1; then
    echo "Skipping absent stack: $stack_name"
    return
  fi

  echo "Deleting $stack_name"
  aws cloudformation delete-stack \
    --region "$REGION" \
    --stack-name "$stack_name"
  deleted_stacks+=("$stack_name")
}

service_stacks=(
  web-portal
  reporting-api
  billing-api
  task-api
  notification-api
  customer-api
)

for service in "${service_stacks[@]}"; do
  delete_stack "${ENVIRONMENT_NAME}-${service}"
done

delete_stack "${ENVIRONMENT_NAME}-database"
delete_stack "${ENVIRONMENT_NAME}-alb"
delete_stack "${ENVIRONMENT_NAME}-ecs-cluster"
delete_stack "${ENVIRONMENT_NAME}-ecr"
delete_stack "${ENVIRONMENT_NAME}-network"

for stack_name in "${deleted_stacks[@]}"; do
  aws cloudformation wait stack-delete-complete \
    --region "$REGION" \
    --stack-name "$stack_name"
done

echo "CloudFormation destroy complete."
