# GitHub Actions to AWS ECS/S3 Reference

This reference gives a complete pattern for a GitHub Actions pipeline targeting AWS with `dev`, `staging`, and `production` environments.

## Target Contract

Create GitHub environments named exactly:

- `dev`
- `staging`
- `production`

For each environment, configure GitHub environment variables:

| Variable | Example |
| --- | --- |
| `AWS_REGION` | `eu-west-3` |
| `AWS_ROLE_TO_ASSUME` | `arn:aws:iam::<account-id>:role/github-actions-my-app-deploy` |
| `ECR_REPOSITORY` | `my-app-api` |
| `ECS_CLUSTER` | `my-app-dev` / `my-app-staging` / `my-app-production` |
| `ECS_SERVICE` | `my-app-api-dev` / `my-app-api-staging` / `my-app-api-production` |
| `ECS_TASK_DEFINITION` | `.aws/task-definition-dev.json` |
| `CONTAINER_NAME` | `api` |
| `S3_BUCKET` | `my-app-front-dev` |
| `VITE_API_BASE_URL` | `https://api.dev.example.com` |
| `CLOUDFRONT_DISTRIBUTION_ID` | optional |
| `MIGRATION_TASK_DEFINITION` | optional ECS task definition for migrations |
| `ECS_SUBNETS` | optional comma-separated subnet ids for migration tasks |
| `ECS_SECURITY_GROUPS` | optional comma-separated security group ids for migration tasks |

Use GitHub secrets only for values the workflow must read. Prefer `AWS_ROLE_TO_ASSUME` plus GitHub OIDC instead of `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

Store application runtime secrets in AWS Secrets Manager or SSM Parameter Store and reference them from the ECS task definition:

```json
{
  "secrets": [
    {
      "name": "DATABASE_URL",
      "valueFrom": "arn:aws:secretsmanager:eu-west-3:<account-id>:secret:my-app:DATABASE_URL_DEV::"
    }
  ]
}
```

## Workflow

Save as `.github/workflows/deploy.yml`.

```yaml
name: Deploy

on:
  pull_request:
  push:
    branches:
      - develop
      - staging
    tags:
      - "v*.*.*"
  workflow_dispatch:
    inputs:
      environment:
        description: "Target environment"
        required: true
        type: choice
        options: [dev, staging, production]

permissions:
  contents: read
  id-token: write

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  resolve-environment:
    runs-on: ubuntu-latest
    outputs:
      environment: ${{ steps.resolve.outputs.environment }}
      image_tag: ${{ steps.resolve.outputs.image_tag }}
      deploy: ${{ steps.resolve.outputs.deploy }}
    steps:
      - id: resolve
        shell: bash
        run: |
          set -euo pipefail

          deploy=true
          if [[ "${{ github.event_name }}" == "pull_request" ]]; then
            deploy=false
            environment=dev
            image_tag=pr-${{ github.event.pull_request.number }}-${GITHUB_SHA::7}
          elif [[ "${{ github.event_name }}" == "workflow_dispatch" ]]; then
            environment="${{ inputs.environment }}"
            image_tag=manual-${GITHUB_RUN_NUMBER}-${GITHUB_SHA::7}
          elif [[ "${GITHUB_REF}" == refs/heads/develop ]]; then
            environment=dev
            image_tag=dev-${GITHUB_RUN_NUMBER}-${GITHUB_SHA::7}
          elif [[ "${GITHUB_REF}" == refs/heads/staging ]]; then
            environment=staging
            image_tag=rc-${GITHUB_RUN_NUMBER}-${GITHUB_SHA::7}
          elif [[ "${GITHUB_REF}" == refs/tags/v* ]]; then
            environment=production
            image_tag="${GITHUB_REF_NAME}"
          else
            deploy=false
            environment=dev
            image_tag=ci-${GITHUB_SHA::7}
          fi

          echo "environment=${environment}" >> "$GITHUB_OUTPUT"
          echo "image_tag=${image_tag}" >> "$GITHUB_OUTPUT"
          echo "deploy=${deploy}" >> "$GITHUB_OUTPUT"

  validate:
    runs-on: ubuntu-latest
    needs: resolve-environment
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npm run lint --if-present
      - run: npm test --if-present
      - run: npm run build --if-present

  build-and-deploy:
    runs-on: ubuntu-latest
    needs: [resolve-environment, validate]
    if: needs.resolve-environment.outputs.deploy == 'true'
    environment: ${{ needs.resolve-environment.outputs.environment }}
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ vars.AWS_REGION }}

      - name: Login to Amazon ECR
        id: ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build frontend
        working-directory: frontend
        env:
          VITE_API_BASE_URL: ${{ vars.VITE_API_BASE_URL }}
        run: |
          set -euo pipefail
          npm ci
          npm run build

      - name: Upload frontend to S3
        run: |
          set -euo pipefail
          aws s3 sync frontend/dist "s3://${{ vars.S3_BUCKET }}/" --delete

      - name: Invalidate CloudFront
        if: vars.CLOUDFRONT_DISTRIBUTION_ID != ''
        run: |
          aws cloudfront create-invalidation \
            --distribution-id "${{ vars.CLOUDFRONT_DISTRIBUTION_ID }}" \
            --paths "/*"

      - name: Build and push backend image
        id: image
        env:
          REGISTRY: ${{ steps.ecr.outputs.registry }}
          IMAGE_TAG: ${{ needs.resolve-environment.outputs.image_tag }}
        run: |
          set -euo pipefail
          image="${REGISTRY}/${{ vars.ECR_REPOSITORY }}:${IMAGE_TAG}"
          docker build \
            --file backend/Dockerfile \
            --tag "$image" \
            backend
          docker push "$image"
          echo "image=$image" >> "$GITHUB_OUTPUT"

      - name: Render ECS task definition
        id: task
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: ${{ vars.ECS_TASK_DEFINITION }}
          container-name: ${{ vars.CONTAINER_NAME }}
          image: ${{ steps.image.outputs.image }}

      - name: Run database migration
        if: vars.MIGRATION_TASK_DEFINITION != ''
        run: |
          set -euo pipefail
          aws ecs run-task \
            --cluster "${{ vars.ECS_CLUSTER }}" \
            --launch-type FARGATE \
            --task-definition "${{ vars.MIGRATION_TASK_DEFINITION }}" \
            --network-configuration "awsvpcConfiguration={subnets=[${{ vars.ECS_SUBNETS }}],securityGroups=[${{ vars.ECS_SECURITY_GROUPS }}],assignPublicIp=DISABLED}"

      - name: Deploy ECS service
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.task.outputs.task-definition }}
          service: ${{ vars.ECS_SERVICE }}
          cluster: ${{ vars.ECS_CLUSTER }}
          wait-for-service-stability: true

      - name: Deployment summary
        run: |
          {
            echo "### Deployment"
            echo "- Environment: ${{ needs.resolve-environment.outputs.environment }}"
            echo "- Image: ${{ steps.image.outputs.image }}"
            echo "- ECS cluster: ${{ vars.ECS_CLUSTER }}"
            echo "- ECS service: ${{ vars.ECS_SERVICE }}"
            echo "- S3 bucket: ${{ vars.S3_BUCKET }}"
          } >> "$GITHUB_STEP_SUMMARY"
```

## ECS Task Definition Skeleton

Store one file per environment when runtime config or secret names differ materially:

```json
{
  "family": "my-app-api-dev",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::<account-id>:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::<account-id>:role/my-app-task-role",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "placeholder",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "NODE_ENV", "value": "production" },
        { "name": "APP_ENV", "value": "dev" },
        { "name": "LOG_LEVEL", "value": "debug" },
        { "name": "CORS_ALLOWED_ORIGINS", "value": "https://app.dev.example.com" }
      ],
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:secretsmanager:eu-west-3:<account-id>:secret:my-app:DATABASE_URL_DEV::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/my-app-api-dev",
          "awslogs-region": "eu-west-3",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

## AWS IAM Minimum Shape

The role assumed by GitHub Actions usually needs:

- ECR: login, image layer upload, put image.
- ECS: register task definition, describe services, update service, run task when migrations are used.
- IAM: pass only the ECS task execution/task roles needed by the service.
- S3: sync object reads/writes/deletes for the frontend bucket.
- CloudFront: create invalidation if used.

Scope resources by environment where possible. For production, protect the GitHub environment with required reviewers.

## Common Variations

- **Backend only**: remove frontend build, S3, and CloudFront steps.
- **Frontend only**: remove ECR/ECS steps and deploy only to S3/CloudFront.
- **Build once, promote many**: build backend image once with a git SHA tag, then deploy the same image to dev/staging/prod. Rebuild frontend per environment only if public values are baked into static assets.
- **GitOps instead of direct ECS**: replace the ECS deploy step with a commit that updates the target environment's desired-state file; let the GitOps controller deploy.
