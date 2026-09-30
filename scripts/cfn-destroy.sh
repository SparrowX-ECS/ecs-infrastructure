#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="${1:-}"
: "${ENVIRONMENT:?Environment argument is required}"
: "${AWS_REGION:?AWS_REGION is not set}"

REGION="$AWS_REGION"
ROOT_STACK_NAME="sparrowx-${ENVIRONMENT}-root-stack"

PARAMETERS_FILE="environments/${ENVIRONMENT}/${ENVIRONMENT}-parameters.yaml"

if [[ ! -f "$PARAMETERS_FILE" ]]; then
    echo "ERROR: Parameters file not found: $PARAMETERS_FILE"
    exit 1
fi

PROJECT_NAME=$(yq -r '.Project.Name' "$PARAMETERS_FILE")

command -v aws >/dev/null 2>&1 || {
  echo "aws CLI is required" >&2
  exit 1
}

# These stacks are outside the root stack and must be deleted first.
SERVICE_STACKS=(
  "${PROJECT_NAME}-${ENVIRONMENT}-web-portal"
  "${PROJECT_NAME}-${ENVIRONMENT}-reporting-api"
  "${PROJECT_NAME}-${ENVIRONMENT}-billing-api"
  "${PROJECT_NAME}-${ENVIRONMENT}-task-api"
  "${PROJECT_NAME}-${ENVIRONMENT}-notification-api"
  "${PROJECT_NAME}-${ENVIRONMENT}-customer-api"
)

stack_exists() {
  local stack_name="$1"

  aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$stack_name" \
    >/dev/null 2>&1
}

delete_stack() {
  local stack_name="$1"

  if ! stack_exists "$stack_name"; then
    echo "Skipping absent stack: $stack_name"
    return 0
  fi

  echo "Deleting $stack_name..."

  aws cloudformation delete-stack \
    --region "$REGION" \
    --stack-name "$stack_name"
}

wait_for_stack_delete() {
  local stack_name="$1"

  if ! stack_exists "$stack_name"; then
    echo "Stack already absent: $stack_name"
    return 0
  fi

  echo "Waiting for deletion: $stack_name"

  if ! aws cloudformation wait stack-delete-complete \
    --region "$REGION" \
    --stack-name "$stack_name"
  then
    echo "Deletion failed for $stack_name." >&2
    echo "Recent stack events:" >&2

    aws cloudformation describe-stack-events \
      --region "$REGION" \
      --stack-name "$stack_name" \
      --query 'StackEvents[?ResourceStatusReason!=null].[LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
      --output table >&2 || true

    return 1
  fi

  echo "Deleted: $stack_name"
}

echo "Environment: $ENVIRONMENT"
echo "Region: $REGION"

echo
echo "Deleting service stacks..."

for stack in "${SERVICE_STACKS[@]}"; do
  delete_stack "$stack"
done

echo
echo "Waiting for service stacks..."

SERVICE_DELETE_FAILED=0

for stack in "${SERVICE_STACKS[@]}"; do
  if ! wait_for_stack_delete "$stack"; then
    SERVICE_DELETE_FAILED=1
  fi
done

if [[ "$SERVICE_DELETE_FAILED" -ne 0 ]]; then
  echo "One or more service stacks failed to delete." >&2
  echo "Root stack will not be deleted." >&2
  exit 1
fi

echo
echo "Deleting root stack..."

if ! stack_exists "$ROOT_STACK_NAME"; then
  echo "Root stack does not exist: $ROOT_STACK_NAME"
  echo "Destroy complete."
  exit 0
fi

aws cloudformation delete-stack \
  --region "$REGION" \
  --stack-name "$ROOT_STACK_NAME"

wait_for_stack_delete "$ROOT_STACK_NAME"

echo
echo "CloudFormation destroy complete."