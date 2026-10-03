# SparrowX ECS infrastructure

This repository is the infrastructure layer for SparrowX, a fictional small SaaS company used to demonstrate platform engineering. The application repositories are sample workloads; this repository provides the repeatable AWS foundation that lets those workloads be onboarded and deployed to separate `dev` and `prod` environments.

The infrastructure is implemented with AWS CloudFormation. The same reusable module set is composed twice through environment-specific root stacks and parameter files. The result is two independently managed environments with their own network, ECS cluster, load balancer, ECR namespace, databases, secrets, logs, and service-stack integration points.

## Architecture

```text
ecs-infrastructure repository
        │
        ├── dev root stack  ──► dev VPC, ECR, ECS, ALB, RDS, secrets, logs
        │                         │
        │                         └── application service stacks
        │
        └── prod root stack ─► prod VPC, ECR, ECS, ALB, RDS, secrets, logs
                                  │
                                  └── application service stacks
```

Each environment contains:

- A VPC with public and private subnets, route tables, internet gateway, and configurable NAT gateways.
- An ECR registry layout for the six sample workloads.
- An ECS cluster with Service Connect defaults for private service-to-service discovery.
- An internet-facing Application Load Balancer and exported listener/security-group values.
- Private PostgreSQL RDS databases for `customer-api`, `notification-api`, `task-api`, and `billing-api`.
- Generated database credentials stored in AWS Secrets Manager.
- CloudFormation exports consumed by application service deployments.
- Optional CloudFront distribution configuration.

ECS tasks and RDS instances are private. Public traffic enters through the ALB. Application service stacks consume the foundation exports and create their own task definitions, services, target groups, listener rules, security groups, IAM roles, and log groups.

## Repository layout

```text
cloudformation/
├── modules/                  # Nested reusable foundation modules
│   ├── private-network.yaml
│   ├── public-network.yaml
│   ├── ecr.yaml
│   ├── ecs-cluster.yaml
│   ├── alb.yaml
│   ├── rds-postgres.yaml
│   ├── ssm-param-stores.yaml
│   └── cloudfront.yaml
└── service.yaml              # Reusable application ECS service template

environments/
├── dev/
│   ├── dev-stack.yaml
│   └── dev-parameters.yaml
└── prod/
    ├── prod-stack.yaml
    └── prod-parameters.yaml

scripts/
├── cfn-plan.sh
├── cfn-apply.sh
└── cfn-destroy.sh
```

## CloudFormation stack composition

The environment root stack composes the nested modules in dependency order:

1. Network foundations and security groups.
2. ECR repositories.
3. ECS cluster and Service Connect namespace.
4. ALB and listener resources.
5. PostgreSQL RDS databases, secrets, and database security groups.
6. SSM parameters and optional CloudFront resources.

The reusable [`cloudformation/service.yaml`](cloudformation/service.yaml) is deployed separately by the application repositories. It accepts the service name, environment, immutable image tag, ECR repository, Fargate size, desired count, ALB route, health-check path, optional database outputs, upstream API URLs, and CORS settings.

## Environment configuration

The environment files intentionally use the same schema while allowing different values:

| Concern | `dev` | `prod` |
| --- | --- | --- |
| Root stack | `sparrowx-dev-root-stack` | `sparrowx-prod-root-stack` |
| Domain | `sparrowx-dev.mo2cloud.com` | `sparrowx-prod.mo2cloud.com` |
| ECR namespace | `sparrowx/dev` | `sparrowx/prod` |
| ECS cluster | Environment-specific | Environment-specific |
| RDS sizing | Demonstration/low cost | Production parameter set |
| CloudFront | Configurable | Configurable |

Environment-qualified names and exports prevent collisions between the two copies of the platform. Review both parameter files when changing shared modules because the module change may affect both environments.

The repository also uses two GitHub Environments, `dev` and `prod`, to track infrastructure deployments separately. Workflow runs and deployment history for each environment remain distinct, making it clear whether a change has only reached development or has also been synchronized to production.

## Local commands

The scripts require AWS CLI, `yq`, and an AWS identity with permission to package, inspect, create change sets, update, and delete the selected CloudFormation stacks.

Set the region and artifact bucket first:

```bash
export AWS_REGION=your-aws-region
export CLOUDFORMATION_ARTIFACT_BUCKET=your-cloudformation-artifact-bucket
```

Create a non-mutating CloudFormation plan:

```bash
./scripts/cfn-plan.sh dev
./scripts/cfn-plan.sh prod
```

Apply an environment:

```bash
./scripts/cfn-apply.sh dev
./scripts/cfn-apply.sh prod
```

Destroy an environment only when intentionally cleaning up the demonstration:

```bash
./scripts/cfn-destroy.sh dev
./scripts/cfn-destroy.sh prod
```

The destroy script deletes known application service stacks before deleting the root stack because those service stacks consume foundation exports. Treat it as a destructive operation and use the GitHub destroy workflow confirmation for shared environments.

## Infrastructure CI/CD

The infrastructure repository uses four GitHub Actions workflows:

### Pull request plan: `cfn-plan.yaml`

Changes to `cloudformation/**`, `environments/**`, `scripts/**`, or `.github/workflows/**` trigger validation. The workflow:

1. Validates both environment parameter files with `yq`.
2. Runs `cfn-lint` against the root, module, and environment templates.
3. Creates a CloudFormation plan for `dev`.
4. Creates a CloudFormation plan for `prod`.
5. Publishes the plans in the GitHub Actions summary and sticky pull-request comments.

The PR plan evaluates both environments so reviewers can see the impact of shared module changes before merge.

### Main branch apply: `cfn-apply.yaml`

After a merge to `main`, the workflow validates both environments, detects the changed scope, and applies only the environment(s) that should receive the change.

| Change | Development apply | Production apply |
| --- | --- | --- |
| `cloudformation/modules/**` | Yes | No automatic apply |
| `environments/dev/**` | Yes | No |
| `scripts/cfn-apply.sh` | Yes | No automatic apply |
| `.github/workflows/cfn-apply.yaml` | Yes | No automatic apply |
| `environments/prod/prod-stack.yaml` | No, unless another dev-scoped path also changed | Yes |
| `environments/prod/prod-parameters.yaml` | No, unless another dev-scoped path also changed | Yes |

The important safety rule is:

> Production deployment is triggered automatically only when files under `environments/prod/**` change—specifically the production stack or production parameters.

Changes to shared CloudFormation modules are deployed to `dev` first. They do not automatically deploy to `prod`. The module change must be tested and verified in development, then synchronized to production deliberately through the manual workflow.

This keeps production from changing merely because a shared module changed and gives the platform operator an explicit verification gate.

### Manual synchronization: `manual-deploy.yaml`

The **Trigger Manual Sync** workflow is available for either environment. Run it manually, choose `dev` or `prod`, type `MANUAL_SYNC`, and it executes `cfn-apply.sh` for the selected target.

Use manual sync when:

- a shared module has been tested and verified in `dev` and now needs to be applied to `prod`;
- a previous production-specific change needs to be re-applied;
- an environment needs to be synchronized without creating another commit;
- an operator wants an explicit deployment event for a selected environment.

Manual sync is the deliberate path for promoting shared infrastructure changes from development to production.

### Environment cleanup: `cfn-destroy.yaml`

The destroy workflow accepts `dev` or `prod` and requires the exact confirmation value `DESTROY`. It runs the ordered destroy script and records the output in the workflow summary.

## AWS/GitHub configuration

The workflows use GitHub OIDC rather than long-lived AWS access keys. The repository or environment variables required by the workflows are:

| Variable | Purpose |
| --- | --- |
| `AWS_ACCOUNT_ID` | AWS account containing the infrastructure. |
| `AWS_REGION` | AWS region for CloudFormation and AWS API calls. |
| `AWS_ROLE_NAME` | IAM role assumed by GitHub through OIDC. |
| `CLOUDFORMATION_ARTIFACT_BUCKET` | S3 bucket used by CloudFormation packaging and change-set planning. |

The assumed role needs permissions appropriate to the selected operation. In particular, plan/apply must be able to read and change CloudFormation resources and supporting AWS services, while destroy must additionally delete the environment resources.

## Operational safeguards

- Plans run for both environments on pull requests.
- Both parameter files and all CloudFormation templates are linted before apply.
- Shared module changes automatically apply to `dev`, not `prod`.
- Production-specific stack/parameter changes can trigger production apply after merge.
- Manual sync provides an explicit path for either environment.
- Stack names, exports, log groups, secrets, and ECR resources are environment-qualified.
- Root-stack apply packages templates into S3 and waits for CloudFormation completion.
- Failed or stale CloudFormation states are handled by the apply/plan scripts with diagnostics.

## Troubleshooting

1. Start with the workflow summary and the CloudFormation stack events.
2. Confirm the expected path changed: shared modules should produce a `dev` apply, while production apply requires `environments/prod/**`.
3. Verify `AWS_REGION`, artifact bucket, OIDC role, and permissions.
4. Run the matching `cfn-plan.sh` command locally or inspect the PR plan comment.
5. For a module change that passed in `dev` but has not reached `prod`, use **Actions → Trigger Manual Sync**, choose `prod`, and enter `MANUAL_SYNC`.

The application service deployment process is documented in the individual service repositories and uses the outputs created here.

## License

This is a proprietary portfolio project. It is publicly viewable but not open source. All rights are reserved. See [LICENSE.md](LICENSE.md).
