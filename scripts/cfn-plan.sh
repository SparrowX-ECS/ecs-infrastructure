#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Requirements
# ============================================================

command -v aws >/dev/null 2>&1 || {
    echo "ERROR: aws CLI is required" >&2
    exit 1
}

command -v yq >/dev/null 2>&1 || {
    echo "ERROR: yq is required" >&2
    exit 1
}


# ============================================================
# Configuration
# ============================================================

ENVIRONMENT="${1:-}"
: "${ENVIRONMENT:?Environment argument is required}"

: "${AWS_REGION:?AWS_REGION is not set}"
: "${CLOUDFORMATION_ARTIFACT_BUCKET:?CLOUDFORMATION_ARTIFACT_BUCKET is not set}"

REGION="$AWS_REGION"
BUCKET="$CLOUDFORMATION_ARTIFACT_BUCKET"

ROOT_STACK_NAME="sparrowx-${ENVIRONMENT}-root-stack"

ROOT_TEMPLATE="environments/${ENVIRONMENT}/${ENVIRONMENT}-stack.yaml"
PARAMETERS_FILE="environments/${ENVIRONMENT}/${ENVIRONMENT}-parameters.yaml"

PACKAGED_TEMPLATE="/tmp/${ENVIRONMENT}-packaged.yaml"
TMP_JSON_PARAMETERS_FILE="/tmp/${ENVIRONMENT}-parameters.json"

ARTIFACT_PREFIX="artifacts/${ENVIRONMENT}"
PACKAGED_S3_KEY="${ENVIRONMENT}/packaged.yaml"

CHANGE_SET_NAME="plan-${GITHUB_RUN_ID:-$(date +%s)}"

# Set to true only when this plan created a temporary CREATE
# change set / REVIEW_IN_PROGRESS stack.
CLEANUP_REVIEW_STACK=false


# ============================================================
# Cleanup
# ============================================================

cleanup() {
    local EXIT_CODE=$?

    if [[ "$CLEANUP_REVIEW_STACK" == "true" ]]; then

        echo
        echo "==> Cleaning up temporary CloudFormation review stack..."

        if aws cloudformation describe-stacks \
            --stack-name "$ROOT_STACK_NAME" \
            --region "$REGION" \
            >/dev/null 2>&1; then

            aws cloudformation delete-stack \
                --stack-name "$ROOT_STACK_NAME" \
                --region "$REGION" \
                || true

            echo "==> Waiting for review stack deletion..."

            aws cloudformation wait stack-delete-complete \
                --stack-name "$ROOT_STACK_NAME" \
                --region "$REGION" \
                || true

        else
            echo "==> Review stack already absent."
        fi

        echo "==> Cleanup complete."
    fi

    exit "$EXIT_CODE"
}

trap cleanup EXIT


# ============================================================
# Validate files
# ============================================================

if [[ ! -f "$ROOT_TEMPLATE" ]]; then
    echo "ERROR: Root template not found: $ROOT_TEMPLATE"
    exit 1
fi

if [[ ! -f "$PARAMETERS_FILE" ]]; then
    echo "ERROR: Parameters file not found: $PARAMETERS_FILE"
    exit 1
fi


# ============================================================
# Read parameters.yaml
# ============================================================

PROJECT_NAME=$(yq -r '.Project.Name' "$PARAMETERS_FILE")
ENVIRONMENT_NAME=$(yq -r '.Project.Environment' "$PARAMETERS_FILE")

VPC_CIDR=$(yq -r '.Network.VpcCidr' "$PARAMETERS_FILE")

PUBLIC_SUBNET_A=$(yq -r '.Network.PublicSubnets.A' "$PARAMETERS_FILE")
PUBLIC_SUBNET_B=$(yq -r '.Network.PublicSubnets.B' "$PARAMETERS_FILE")
PUBLIC_SUBNET_C=$(yq -r '.Network.PublicSubnets.C' "$PARAMETERS_FILE")

PRIVATE_SUBNET_A=$(yq -r '.Network.PrivateSubnets.A' "$PARAMETERS_FILE")
PRIVATE_SUBNET_B=$(yq -r '.Network.PrivateSubnets.B' "$PARAMETERS_FILE")
PRIVATE_SUBNET_C=$(yq -r '.Network.PrivateSubnets.C' "$PARAMETERS_FILE")

NAT_GW_A=$(yq -r '.Network.NatGateways.A' "$PARAMETERS_FILE")
NAT_GW_B=$(yq -r '.Network.NatGateways.B' "$PARAMETERS_FILE")
NAT_GW_C=$(yq -r '.Network.NatGateways.C' "$PARAMETERS_FILE")

ALB_SCHEME=$(yq -r '.LoadBalancer.Scheme' "$PARAMETERS_FILE")

REPOSITORIES=$(yq -r '.ECR.Repositories | join(",")' "$PARAMETERS_FILE")

POSTGRES_DATABASES=$(yq -r '.PostgreSQL.Databases | join(",")' "$PARAMETERS_FILE")
POSTGRES_MULTIAZ=$(yq -r '.PostgreSQL.MultiAZ' "$PARAMETERS_FILE")
POSTGRES_INSTANCE_CLASS=$(yq -r '.PostgreSQL.InstanceClass' "$PARAMETERS_FILE")
POSTGRES_STORAGE=$(yq -r '.PostgreSQL.AllocatedStorage' "$PARAMETERS_FILE")
POSTGRES_ENGINE_VERSION=$(yq -r '.PostgreSQL.EngineVersion' "$PARAMETERS_FILE")

CLOUDFRONT_CERTIFICATE_ARN=$(yq -r '.CloudFront.CertificateArn' "$PARAMETERS_FILE")
DOMAIN_NAME=$(yq -r '.CloudFront.DomainName' "$PARAMETERS_FILE")

# Feature Toggle Variables
NETWORK_MODE=$(yq -r '.Network.Mode' "$PARAMETERS_FILE")
ECR_MODE=$(yq -r '.ECR.Mode' "$PARAMETERS_FILE")
ECS_MODE=$(yq -r '.ECS.Mode' "$PARAMETERS_FILE")
LOADBALANCER_MODE=$(yq -r '.LoadBalancer.Mode' "$PARAMETERS_FILE")
POSTGRESQL_MODE=$(yq -r '.PostgreSQL.Mode' "$PARAMETERS_FILE")
CLOUDFRONT_MODE=$(yq -r '.CloudFront.Mode' "$PARAMETERS_FILE")


# ============================================================
# Validate environment consistency
# ============================================================

if [[ "$ENVIRONMENT_NAME" != "$ENVIRONMENT" ]]; then
    echo "ERROR: Environment mismatch."
    echo "  Script argument: $ENVIRONMENT"
    echo "  Parameters file: $ENVIRONMENT_NAME"
    exit 1
fi


# ============================================================
# Generate AWS CLI parameter file
# ============================================================

cat > "$TMP_JSON_PARAMETERS_FILE" <<EOF
[
  {
    "ParameterKey": "ProjectName",
    "ParameterValue": "$PROJECT_NAME"
  },
  {
    "ParameterKey": "EnvironmentName",
    "ParameterValue": "$ENVIRONMENT_NAME"
  },
  {
    "ParameterKey": "VpcCidr",
    "ParameterValue": "$VPC_CIDR"
  },
  {
    "ParameterKey": "PublicSubnetACidr",
    "ParameterValue": "$PUBLIC_SUBNET_A"
  },
  {
    "ParameterKey": "PublicSubnetBCidr",
    "ParameterValue": "$PUBLIC_SUBNET_B"
  },
  {
    "ParameterKey": "PublicSubnetCCidr",
    "ParameterValue": "$PUBLIC_SUBNET_C"
  },
  {
    "ParameterKey": "PrivateSubnetACidr",
    "ParameterValue": "$PRIVATE_SUBNET_A"
  },
  {
    "ParameterKey": "PrivateSubnetBCidr",
    "ParameterValue": "$PRIVATE_SUBNET_B"
  },
  {
    "ParameterKey": "PrivateSubnetCCidr",
    "ParameterValue": "$PRIVATE_SUBNET_C"
  },
  {
    "ParameterKey": "NatGWSubnetA",
    "ParameterValue": "$NAT_GW_A"
  },
  {
    "ParameterKey": "NatGWSubnetB",
    "ParameterValue": "$NAT_GW_B"
  },
  {
    "ParameterKey": "NatGWSubnetC",
    "ParameterValue": "$NAT_GW_C"
  },
  {
    "ParameterKey": "Scheme",
    "ParameterValue": "$ALB_SCHEME"
  },
  {
    "ParameterKey": "ECRRepositories",
    "ParameterValue": "$REPOSITORIES"
  },
  {
    "ParameterKey": "PostgresDataBases",
    "ParameterValue": "$POSTGRES_DATABASES"
  },
  {
    "ParameterKey": "PostgresDBMultiAZ",
    "ParameterValue": "$POSTGRES_MULTIAZ"
  },
  {
    "ParameterKey": "PostgresDBInstancesClass",
    "ParameterValue": "$POSTGRES_INSTANCE_CLASS"
  },
  {
    "ParameterKey": "PostgresDBAllocatedStorage",
    "ParameterValue": "$POSTGRES_STORAGE"
  },
  {
    "ParameterKey": "PostgresDBEngineVersion",
    "ParameterValue": "$POSTGRES_ENGINE_VERSION"
  },
  {
    "ParameterKey": "CloudFrontCertificateArn",
    "ParameterValue": "$CLOUDFRONT_CERTIFICATE_ARN"
  },
  {
    "ParameterKey": "DomainName",
    "ParameterValue": "$DOMAIN_NAME"
  },
  {
    "ParameterKey": "VPCMode",
    "ParameterValue": "$NETWORK_MODE"
  },
  {
    "ParameterKey": "ECRMode",
    "ParameterValue": "$ECR_MODE"
  },
  {
    "ParameterKey": "ECSClusterMode",
    "ParameterValue": "$ECS_MODE"
  },
  {
    "ParameterKey": "LoadBalancerMode",
    "ParameterValue": "$LOADBALANCER_MODE"
  },
  {
    "ParameterKey": "PostgresDBMode",
    "ParameterValue": "$POSTGRESQL_MODE"
  },
  {
    "ParameterKey": "CloudFrontMode",
    "ParameterValue": "$CLOUDFRONT_MODE"
  }
]
EOF


# ============================================================
# Validate generated parameter file
# ============================================================

echo "==> Validating generated parameter file..."

jq empty "$TMP_JSON_PARAMETERS_FILE"


# ============================================================
# Package CloudFormation templates
# ============================================================

echo "==> Packaging CloudFormation templates..."

aws cloudformation package \
    --template-file "$ROOT_TEMPLATE" \
    --s3-bucket "$BUCKET" \
    --s3-prefix "$ARTIFACT_PREFIX" \
    --output-template-file "$PACKAGED_TEMPLATE" \
    --region "$REGION"


# ============================================================
# Check stack status
# ============================================================

echo "==> Checking stack status..."

STACK_STATUS=$(
    aws cloudformation describe-stacks \
        --stack-name "$ROOT_STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text \
        2>/dev/null || echo "NOT_FOUND"
)

echo "Current stack status: $STACK_STATUS"

# ============================================================
# Handle existing REVIEW_IN_PROGRESS stack
# ============================================================

if [[ "$STACK_STATUS" == "REVIEW_IN_PROGRESS" ]]; then

    echo
    echo "==> Found stale REVIEW_IN_PROGRESS stack."
    echo "==> Deleting it before creating a fresh plan..."

    aws cloudformation delete-stack \
        --stack-name "$ROOT_STACK_NAME" \
        --region "$REGION"

    aws cloudformation wait stack-delete-complete \
        --stack-name "$ROOT_STACK_NAME" \
        --region "$REGION"

    STACK_STATUS="NOT_FOUND"

    echo "==> Stale review stack removed."
fi


# ============================================================
# Determine change set type
# ============================================================

if [[ "$STACK_STATUS" == "NOT_FOUND" ]]; then

    CHANGE_SET_TYPE="CREATE"

    # A CREATE change set creates a temporary REVIEW_IN_PROGRESS
    # stack. It must therefore be deleted during cleanup.
    CLEANUP_REVIEW_STACK=true

else

    CHANGE_SET_TYPE="UPDATE"

fi

echo "==> Change set type: $CHANGE_SET_TYPE"


# ============================================================
# Create change set
# ============================================================

echo "==> Creating CloudFormation change set..."

aws cloudformation create-change-set \
    --stack-name "$ROOT_STACK_NAME" \
    --change-set-name "$CHANGE_SET_NAME" \
    --change-set-type "$CHANGE_SET_TYPE" \
    --template-body "file://${PACKAGED_TEMPLATE}" \
    --parameters "file://${TMP_JSON_PARAMETERS_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --region "$REGION"


# ============================================================
# Wait for change set
# ============================================================

echo "==> Waiting for change set..."

aws cloudformation wait \
    change-set-create-complete \
    --stack-name "$ROOT_STACK_NAME" \
    --change-set-name "$CHANGE_SET_NAME" \
    --region "$REGION"


# ============================================================
# Show resource changes
# ============================================================

echo
echo "============================================================"
echo "CloudFormation resource changes"
echo "============================================================"

aws cloudformation describe-change-set \
    --stack-name "$ROOT_STACK_NAME" \
    --change-set-name "$CHANGE_SET_NAME" \
    --region "$REGION" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' \
    --output table


# ============================================================
# Plan complete
# ============================================================

echo
echo "============================================================"
echo "CloudFormation plan complete"
echo "============================================================"
echo "No changes were executed."