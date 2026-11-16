---
name: devops-pipeline-design
description: Design cloud deployment CI/CD pipelines (GitHub Actions, Kubernetes GitOps, AWS ECS/S3/ECR). Use when creating or reviewing deploy workflows, environment promotion, build-time vs runtime configuration, or secrets handling. Ships a GitHub Actions to AWS ECS/S3 workflow template.
---

# DevOps Pipeline Design

## Principles

- **Separate four things**: target environment (cloud account, region, cluster, DNS), pipeline environment (CI variables/approvals), artifact (immutable image/bundle, deployed by tag or digest), deployment authority (the single system allowed to mutate runtime).
- **One deployment authority per target**: GitOps (CI only commits desired state, ArgoCD/Flux applies, CI never holds cluster credentials) or direct (CI pushes to ECR, registers a task definition, updates the ECS service). Never both.
- **Event to environment mapping**: PR = validate only; `develop` = dev; `staging` = staging; semver tag or release = production behind a protected environment. Use the same names (`dev`, `staging`, `production`) in CI, cloud resources, DNS and code.
- **Tags**: git SHA (or `rc-<run>-<sha>`) for non-prod, semver tag for production. Never deploy `latest`.
- **Build once, promote many**, except static frontends whose public URLs are baked at build time.

## Classify every variable

| Kind | Examples | Where |
| --- | --- | --- |
| CI secret | registry password, Git token | CI secret store; prefer OIDC over static cloud keys |
| CI config | region, repo, service, bucket | CI environment variables |
| Build-time public | `VITE_*`, `NEXT_PUBLIC_*`, public DSN | CI env vars; not secrets, but scan built assets for internal tokens |
| Docker build secret | private npm/git token | BuildKit `--secret`, never `--build-arg` |
| Runtime config | `LOG_LEVEL`, CORS, replicas | ECS task definition `environment`, Helm values |
| Runtime secret | `DATABASE_URL`, JWT secret | Secrets Manager/SSM via ECS `secrets`, Kubernetes Secret; not GitHub unless the pipeline reads it |

## Safety rules

- Fail fast when a required variable is missing.
- Run migrations before the service update only if backward compatible; otherwise use expand/contract.
- Record the deployed tag in the job summary, release notes or GitOps commit.
- GitOps commits pushed by CI carry `[skip ci]` to avoid loops.
- When translating between CI platforms (Bitbucket, Azure DevOps to GitHub Actions), keep artifact naming, environment mapping, secret ownership and deployment authority unchanged; translate syntax last.

## Templates

- `templates/deploy-ecs.yml`: GitHub Actions workflow, dev/staging/production, OIDC, ECR, ECS (with optional migration task), S3 + CloudFront. The header comment lists the required GitHub environment variables.
- `templates/task-definition.json`: per-environment Fargate task definition skeleton with `environment` and `secrets` blocks.

The assumed IAM role needs: ECR push, ECS register/describe/update (and run-task for migrations), `iam:PassRole` limited to the task roles, S3 sync on the frontend bucket, CloudFront invalidation. Scope per environment.
