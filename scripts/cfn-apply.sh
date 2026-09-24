#!/usr/bin/env bash

set -euo pipefail

command -v aws >/dev/null 2>&1 || { echo "aws CLI is required" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CFN_DIR="$SCRIPT_DIR/../cloudformation"
PARAMETERS_FILE="$SCRIPT_DIR/../parameters.yaml"

ENVIRONMENT_NAME="$(yq -r '.environment.name' "$PARAMETERS_FILE")"
REGION="$(yq -r '.environment.region' "$PARAMETERS_FILE")"

VPC_CIDR="$(yq -r '.network.vpc_cidr' "$PARAMETERS_FILE")"
AZ_A="$(yq -r '.network.availability_zones.a' "$PARAMETERS_FILE")"
AZ_B="$(yq -r '.network.availability_zones.b' "$PARAMETERS_FILE")"
PUBLIC_SUBNET_A="$(yq -r '.network.public_subnets.a' "$PARAMETERS_FILE")"
PUBLIC_SUBNET_B="$(yq -r '.network.public_subnets.b' "$PARAMETERS_FILE")"
PRIVATE_SUBNET_A="$(yq -r '.network.private_subnets.a' "$PARAMETERS_FILE")"
PRIVATE_SUBNET_B="$(yq -r '.network.private_subnets.b' "$PARAMETERS_FILE")"

DB_ENGINE_VERSION="$(yq -r '.database.engine_version' "$PARAMETERS_FILE")"
DB_INSTANCE_CLASS="$(yq -r '.database.instance_class' "$PARAMETERS_FILE")"
DB_ALLOCATED_STORAGE="$(yq -r '.database.allocated_storage' "$PARAMETERS_FILE")"
DB_BACKUP_RETENTION="$(yq -r '.database.backup_retention_days' "$PARAMETERS_FILE")"
DB_MULTI_AZ="$(yq -r '.database.multi_az' "$PARAMETERS_FILE")"
ALB_SCHEME="$(yq -r '.alb.scheme' "$PARAMETERS_FILE")"

deploy_stack() {
  local stack_name="$1"
  local template="$2"
  shift 2

  echo "Deploying $stack_name"
  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --template-file "$template" \
    --parameter-overrides "$@" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset
}

deploy_stack \
  "${ENVIRONMENT_NAME}-network" \
  "$CFN_DIR/network.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME" \
  VpcCidr="$VPC_CIDR" \
  AvailabilityZoneA="$AZ_A" \
  AvailabilityZoneB="$AZ_B" \
  PublicSubnetACidr="$PUBLIC_SUBNET_A" \
  PublicSubnetBCidr="$PUBLIC_SUBNET_B" \
  PrivateSubnetACidr="$PRIVATE_SUBNET_A" \
  PrivateSubnetBCidr="$PRIVATE_SUBNET_B"

deploy_stack \
  "${ENVIRONMENT_NAME}-ecr" \
  "$CFN_DIR/ecr.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME"

deploy_stack \
  "${ENVIRONMENT_NAME}-ecs-cluster" \
  "$CFN_DIR/ecs-cluster.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME"

deploy_stack \
  "${ENVIRONMENT_NAME}-alb" \
  "$CFN_DIR/alb.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME" \
  Scheme="$ALB_SCHEME"

deploy_stack \
  "${ENVIRONMENT_NAME}-database" \
  "$CFN_DIR/database.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME" \
  DBEngineVersion="$DB_ENGINE_VERSION" \
  DBInstanceClass="$DB_INSTANCE_CLASS" \
  DBAllocatedStorage="$DB_ALLOCATED_STORAGE" \
  DBBackupRetentionDays="$DB_BACKUP_RETENTION" \
  DBMultiAZ="$DB_MULTI_AZ"

echo "CloudFormation apply complete."
