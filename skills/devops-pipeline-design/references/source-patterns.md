# Source Patterns Extracted From Existing Pipelines

Use these patterns as concepts, not as copy-paste vendor lock-in.

## Bitbucket to Kubernetes GitOps

Observed shape:

- Bitbucket Pipelines builds Docker images for backend/frontend/services.
- `staging` branch deploys to pre-production (`pprod` or staging) by producing `rc-${BITBUCKET_BUILD_NUMBER}` style tags.
- Semver tags deploy to production by using the Git tag as the image tag.
- Each build step writes a marker artifact such as `.built/backend` containing the exact pushed tag.
- A final GitOps step patches `helm/<service>/values-pprod.yaml` or `helm/<service>/values-prod.yaml`, commits with `[skip ci]`, and pushes back to the repo.
- The pipeline never runs `helm`, `kubectl`, or cluster credentials. ArgoCD watches the Helm values and applies changes to Kubernetes.
- Some repos rebuild every service on staging/tag; others use changeset filters and update only services with `.built/*` markers.

Concepts to preserve:

- CI owns build and desired-state Git changes.
- ArgoCD owns cluster mutation.
- Helm values hold environment-specific runtime configuration: image tag, replicas, HPA, resource requests/limits, public service URLs, feature flags, and ConfigMap data.
- Kubernetes Secret references hold runtime secrets. Frontend runtime secrets are avoided; public frontend values are baked at build time.
- Docker build secrets are passed with BuildKit `--secret` for private npm/git dependencies.

## Azure DevOps to AWS ECS/S3

Observed shape:

- Azure DevOps triggers on `staging` branch and semver tags.
- A variable derives `appEnv` from the source ref: branch means staging, tag means production.
- Frontend is built with public `VITE_*` values and published as an artifact, then uploaded to `s3://<bucket-prefix>-<env>/`.
- Backend is built into a Docker image, tagged `RC-<buildId>` for staging or the semver tag for production, and pushed to ECR.
- ECS task definitions are stored per environment and include placeholders such as `__TAG__` and `__MIGRATION__`.
- A migration task runs before the service update.
- Runtime config lives in the ECS task definition `environment` block.
- Runtime secrets are referenced from AWS Secrets Manager in the ECS task definition `secrets` block.
- Network configuration for ECS tasks is stored outside the pipeline as structured JSON.

Concepts to preserve:

- Target environment controls S3 bucket, ECS cluster, ECS service, task definition, network, runtime variables, and secret names.
- The pipeline needs AWS deployment identity, ECR permissions, ECS permissions, S3 permissions, and optionally CloudFront permissions.
- Runtime secrets should stay in AWS; GitHub/Azure/Bitbucket secrets should contain only CI credentials or federation configuration.

## Variable Taxonomy

| Category | Examples | Owner | Exposure |
| --- | --- | --- | --- |
| CI secret | registry password, Git token, legacy AWS key | CI platform | masked, rotate on leak |
| CI config | AWS region, ECR repository, ECS service, S3 bucket | CI environment vars | visible in logs |
| Docker build secret | npm token, private git token | CI secret passed by BuildKit | never in image layers |
| Build-time public config | `VITE_API_BASE_URL`, public Sentry DSN | CI environment vars | baked into static assets |
| Runtime config | `LOG_LEVEL`, `CORS_ALLOWED_ORIGINS`, replica count | Helm values, ECS task definition, app config | visible to operators |
| Runtime secret | `DATABASE_URL`, JWT secret, API key | Secrets Manager, SSM, Kubernetes Secret | injected at runtime |

## Translation Checklist

- Identify source triggers and target environment mapping before translating syntax.
- Keep artifact tags deterministic and inspectable.
- Keep build-time and runtime variables separate.
- Replace static cloud credentials with OIDC when moving to GitHub Actions.
- Decide whether GitHub Actions directly deploys or only updates GitOps state.
- Keep production deploys constrained by protected environment approval or semver tag/release policy.
