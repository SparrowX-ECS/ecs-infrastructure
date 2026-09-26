# SparrowX ECS Infrastructure

The infrastructure backbone for the SparrowX microservices platform. It provisions the shared AWS foundation used by all services and provides the reusable CloudFormation template used to deploy each service onto Amazon ECS.

## Architecture

The platform runs in `eu-west-1` by default and is built from independent CloudFormation stacks:

```text
CloudFront (optional HTTPS edge)
            │
            ▼
Application Load Balancer ── path-based routing ──► ECS services on Fargate
            │                                      ├── customer-api
            │                                      ├── notification-api
            │                                      ├── task-api
            │                                      ├── billing-api
            │                                      ├── reporting-api
            │                                      └── web-portal
            │
            └── VPC: public subnets for the ALB, private subnets for ECS and RDS

ECR repositories ──► immutable service images tagged with Git commit SHAs
RDS PostgreSQL ────► customer, notification, task, and billing databases
Secrets Manager ───► database credentials injected into ECS tasks
CloudWatch Logs ───► service log groups
```

The stack dependency order is:

1. `network.yaml` creates the VPC, public/private subnets, routing, NAT, and shared security groups.
2. `ecr.yaml` creates one ECR repository per application.
3. `ecs-cluster.yaml` creates the ECS cluster and shared ECS resources.
4. `alb.yaml` creates the internet-facing ALB and HTTP listener.
5. `database.yaml` creates private PostgreSQL RDS instances, subnet groups, security groups, and Secrets Manager secrets for the stateful services.
6. `cloudfront.yaml` optionally adds an HTTPS CloudFront distribution in front of the ALB.
7. `service.yaml` is applied separately for every application to create its ECS task definition, Fargate service, target group, listener rule, IAM roles, security group, and CloudWatch log group.

CloudFormation exports connect these stacks without hard-coding resource IDs. ECS tasks run without public IP addresses in private subnets. The ALB is the public entry point, and path-based rules route requests such as `/api/customer/*` and `/api/reporting/*` to the appropriate service.

## Service deployment flow

Each application repository contains an `ecs-parameters.yaml` file describing its service stack, ECR repository, container settings, ALB path, health check, and database requirements. For example, [`customer-api/ecs-parameters.yaml`](https://github.com/SparrowX-ECS/customer-api/blob/main/ecs-parameters.yaml) points to the shared `sparrowx-database` stack and the `customerdb` database.

The application workflow delegates to the reusable workflows in [`workflows-templates`](https://github.com/SparrowX-ECS/workflows-templates):

```text
Pull request / push to main
             │
             ▼
Detect changes (changes.yaml)
             │
             ├── code changed ──► test.yaml
             │                         │
             │                         ▼
             │                    build.yaml
             │                    Docker build + push to ECR
             │
             └── deploy-relevant change
                                   │
                                   ▼
                              deploy.yaml
                                   │
                read ecs-parameters.yaml and shared stack outputs
                                   │
                                   ▼
                 CloudFormation deploy of service.yaml
                                   │
                                   ▼
             ECS rolling deployment using the new image SHA
```

For a service with a database, the deploy workflow resolves the RDS endpoint, port, secret ARN, and database security group from the shared database stack. It passes those values to `service.yaml`; the template grants the ECS task access to the database security group and injects credentials from Secrets Manager. The application connects to PostgreSQL through `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, and `DB_PASSWORD`.

The image is tagged with the Git commit SHA. A normal code change builds and pushes that image, then the service stack is updated with the same immutable tag. A deployment-only change can reuse the current image. The manual redeploy workflow uses the same deployment template with `update-image: false` to restart the ECS service without rebuilding an image.

## Repository layout

```text
.
├── cloudformation/
│   ├── network.yaml       # VPC and subnet foundation
│   ├── ecr.yaml           # ECR repositories
│   ├── ecs-cluster.yaml   # ECS cluster
│   ├── alb.yaml           # ALB and listener
│   ├── database.yaml      # PostgreSQL RDS and secrets
│   ├── service.yaml       # Reusable per-service ECS template
│   └── cloudfront.yaml    # Optional HTTPS edge
├── scripts/
│   ├── cfn-plan.sh        # Change-set preview
│   ├── cfn-apply.sh       # Shared environment deployment
│   └── cfn-destroy.sh     # Confirmed environment cleanup
├── parameters.yaml        # Shared environment parameters
└── .github/workflows/     # Plan, apply, and destroy automation
```

## Deploy the shared platform

Prerequisites:

- AWS CLI configured for the target account
- `yq`
- An IAM role usable by GitHub Actions, or equivalent local AWS permissions
- A CloudFront ACM certificate ARN in `us-east-1` when CloudFront is enabled

Review `parameters.yaml`, then run:

```bash
./scripts/cfn-plan.sh
./scripts/cfn-apply.sh
```

The repository workflows run the same operations automatically. Pull requests run validation and a change-set plan; pushes to `main` validate and apply the shared stacks. The destroy workflow is manual and requires the exact confirmation value `DESTROY`.

## Operational characteristics

- ECS services use Fargate, `awsvpc` networking, private subnets, and service discovery through ECS Service Connect.
- ALB target groups perform HTTP health checks, normally against `/health`.
- ECS deployment circuit breakers can roll back failed deployments.
- Database credentials are generated and stored in Secrets Manager; they are not committed to application repositories.
- Application and infrastructure logs are sent to CloudWatch Logs.
- The current default database configuration is PostgreSQL 16 on small, encrypted RDS instances with one day of automated backup retention and Multi-AZ disabled.

This project is intentionally a focused ECS/CloudFormation platform. Prometheus and Grafana integration can be added as an observability enhancement, but they are not required by the core infrastructure path.
