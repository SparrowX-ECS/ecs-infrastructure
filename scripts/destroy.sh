#!/bin/bash

set -e

services=(
  sparrowx-web-portal
  sparrowx-reporting-api
  sparrowx-billing-api
  sparrowx-task-api
  sparrowx-notification-api
  sparrowx-customer-api
)

for stack in "${services[@]}"; do
  aws cloudformation delete-stack --stack-name "$stack"
done

# Wait for all service stacks to disappear
for stack in "${services[@]}"; do
  aws cloudformation wait stack-delete-complete \
    --stack-name "$stack"
done

aws cloudformation delete-stack --stack-name sparrowx-database
aws cloudformation wait stack-delete-complete \
  --stack-name sparrowx-database

aws cloudformation delete-stack --stack-name sparrowx-alb
aws cloudformation wait stack-delete-complete \
  --stack-name sparrowx-alb

aws cloudformation delete-stack --stack-name sparrowx-cluster
aws cloudformation wait stack-delete-complete \
  --stack-name sparrowx-cluster

aws cloudformation delete-stack --stack-name sparrowx-ecr
aws cloudformation wait stack-delete-complete \
  --stack-name sparrowx-ecr

aws cloudformation delete-stack --stack-name sparrowx-network