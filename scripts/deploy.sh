#!/usr/bin/env bash

set -euo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CFN_DIR="$SCRIPT_DIR/../cloudformation"
PARAMETERS_FILE="$SCRIPT_DIR/../parameters.yaml"

# --------------------------------------------------
# Load configuration
# --------------------------------------------------

ENVIRONMENT_NAME="$(yq -r '.environment.name' "$PARAMETERS_FILE")"
REGION="$(yq -r '.environment.region' "$PARAMETERS_FILE")"

# Network
VPC_CIDR="$(yq -r '.network.vpc_cidr' "$PARAMETERS_FILE")"

AZ_A="$(yq -r '.network.availability_zones.a' "$PARAMETERS_FILE")"
AZ_B="$(yq -r '.network.availability_zones.b' "$PARAMETERS_FILE")"

PUBLIC_SUBNET_A="$(yq -r '.network.public_subnets.a' "$PARAMETERS_FILE")"
PUBLIC_SUBNET_B="$(yq -r '.network.public_subnets.b' "$PARAMETERS_FILE")"

PRIVATE_SUBNET_A="$(yq -r '.network.private_subnets.a' "$PARAMETERS_FILE")"
PRIVATE_SUBNET_B="$(yq -r '.network.private_subnets.b' "$PARAMETERS_FILE")"

# Database
DB_ENGINE="$(yq -r '.database.engine' "$PARAMETERS_FILE")"
DB_ENGINE_VERSION="$(yq -r '.database.engine_version' "$PARAMETERS_FILE")"
DB_INSTANCE_CLASS="$(yq -r '.database.instance_class' "$PARAMETERS_FILE")"
DB_ALLOCATED_STORAGE="$(yq -r '.database.allocated_storage' "$PARAMETERS_FILE")"
DB_BACKUP_RETENTION="$(yq -r '.database.backup_retention_days' "$PARAMETERS_FILE")"
DB_MULTI_AZ="$(yq -r '.database.multi_az' "$PARAMETERS_FILE")"

# ECS
ECS_CLUSTER_NAME="$(yq -r '.ecs.cluster_name' "$PARAMETERS_FILE")"

# ALB
ALB_SCHEME="$(yq -r '.alb.scheme' "$PARAMETERS_FILE")"

# --------------------------------------------------
# Stack names
# --------------------------------------------------

NETWORK_STACK="${ENVIRONMENT_NAME}-network"
ECR_STACK="${ENVIRONMENT_NAME}-ecr"
ECS_CLUSTER_STACK="${ENVIRONMENT_NAME}-ecs-cluster"
ALB_STACK="${ENVIRONMENT_NAME}-alb"
DATABASE_STACK="${ENVIRONMENT_NAME}-database"

# --------------------------------------------------
# Helper
# --------------------------------------------------

deploy_stack() {
  local stack_name="$1"
  local template="$2"
  shift 2

  echo ""
  echo "=========================================="
  echo "Deploying: $stack_name"
  echo "=========================================="

  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --template-file "$template" \
    --parameter-overrides "$@" \
    --capabilities CAPABILITY_NAMED_IAM

  echo "$stack_name stack deployed"
}

# --------------------------------------------------
# Shared infrastructure
# --------------------------------------------------

deploy_stack \
  "$NETWORK_STACK" \
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
  "$ECR_STACK" \
  "$CFN_DIR/ecr.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME"

deploy_stack \
  "$ECS_CLUSTER_STACK" \
  "$CFN_DIR/ecs-cluster.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME" \
  ClusterName="$ECS_CLUSTER_NAME"

deploy_stack \
  "$ALB_STACK" \
  "$CFN_DIR/alb.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME" \
  LoadBalancerScheme="$ALB_SCHEME"

deploy_stack \
  "$DATABASE_STACK" \
  "$CFN_DIR/database.yaml" \
  EnvironmentName="$ENVIRONMENT_NAME" \
  Engine="$DB_ENGINE" \
  EngineVersion="$DB_ENGINE_VERSION" \
  DBInstanceClass="$DB_INSTANCE_CLASS" \
  AllocatedStorage="$DB_ALLOCATED_STORAGE" \
  BackupRetentionDays="$DB_BACKUP_RETENTION" \
  MultiAZ="$DB_MULTI_AZ"

echo ""
echo "=========================================="
echo "All SparrowX infrastructure deployed!"
echo "=========================================="