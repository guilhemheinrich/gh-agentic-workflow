---
name: devops-pipeline-design
description: Design cloud deployment CI/CD pipelines from first principles. Use when creating or reviewing GitHub Actions, Bitbucket Pipelines, Azure DevOps, Kubernetes GitOps, AWS ECS/S3/ECR, Docker build, environment promotion, runtime configuration, build-time variables, or secrets handling workflows.
---

# DevOps Pipeline Design

## Lexicon

- **Target infrastructure environment**: A deployable runtime boundary such as `dev`, `staging`, `pprod`, or `production`. Define it by cloud account or subscription, region, network, namespace or cluster, service names, DNS, secret store, resource quotas, and approval rules.
- **Pipeline environment**: The CI/CD platform environment used for variables, secrets, logs, approvals, and audit trails. Do not confuse it with the runtime environment; map it explicitly.
- **Artifact**: The immutable output produced by CI: container image, static frontend bundle, package, chart, or task definition. Deploy by reference to an artifact tag or digest.
- **Promotion**: Moving an artifact from one target environment to another. Prefer rebuilding only when build-time public configuration differs by environment.
- **Automatic deployment**: A deployment triggered by branch, tag, release, or GitOps commit without manual commands. Keep production automatic only behind deliberate gates such as semver tags, release events, protected environments, or required reviewers.
- **Build-time variable**: Value consumed while creating an artifact, for example `VITE_API_BASE_URL` baked into a static frontend bundle. Public client-side values are not secrets.
- **Runtime configuration**: Non-secret value read by the running service, for example `LOG_LEVEL`, `CORS_ALLOWED_ORIGINS`, replica count, CPU/memory, or S3 bucket name. Store in Helm values, ECS task definitions, app config, parameter stores, or platform variables.
- **Secret**: Credential or token whose disclosure requires rotation. Store in the CI secret store only when the pipeline itself needs it; store application runtime secrets in the cloud/runtime secret store.
- **Deployment authority**: The system allowed to mutate runtime infrastructure. Examples: ArgoCD for Kubernetes, GitHub Actions for ECS service updates, Azure DevOps templates for ECS tasks.

## Workflow

1. Inventory the deployment surface before writing YAML:
   - Source events: PR, branch, tag, manual dispatch.
   - Artifacts: images, static bundles, packages, task definitions, Helm values.
   - Target environments: dev, staging, production, including cloud account, region, network, service names, domains, secret store, and approval gate.
   - Deployment authority: direct deploy from CI, GitOps reconciliation, or a shared deployment template.

2. Choose the environment mapping:
   - PR: validation only unless ephemeral previews are explicitly required.
   - `develop` or `dev`: deploy to dev.
   - `staging`: deploy to staging or pprod.
   - Semver tag or GitHub release: deploy to production.
   - Use platform environment names (`dev`, `staging`, `production`) to scope variables, secrets, approvals, and audit.

3. Classify every variable:
   - CI secret: registry password, Git token, legacy cloud access key. Prefer cloud OIDC instead of long-lived keys.
   - CI configuration: region, repository name, service name, S3 bucket, public frontend URL.
   - Build-time public value: `VITE_*`, `NEXT_PUBLIC_*`, public Sentry DSN.
   - Docker build secret: private npm or git token; pass with BuildKit `--secret`, not `--build-arg`.
   - Runtime config: ECS task definition `environment`, Helm `config`, ConfigMap, app settings.
   - Runtime secret: ECS `secrets` from Secrets Manager/SSM, Kubernetes Secret, ExternalSecret, Key Vault, or equivalent.

4. Build immutable artifacts:
   - Tag images with an environment-independent version when possible: git SHA for dev/staging, semver tag for production.
   - Use per-environment frontend builds only when static assets must bake different public URLs.
   - Avoid relying on `latest` for deployment. Pushing `latest` is acceptable for convenience, but deploy the explicit tag or digest.

5. Deploy with one clear authority:
   - Kubernetes GitOps: CI builds images and updates Git state only; ArgoCD or Flux applies to the cluster.
   - Direct AWS ECS: CI pushes to ECR, renders/registers a task definition, runs migrations if needed, then updates the ECS service.
   - Static frontend on AWS: CI builds the bundle, uploads to the environment S3 bucket, and invalidates CloudFront when present.

6. Add safety checks:
   - Fail fast when required variables are missing.
   - Keep production behind protected environments or semver tags.
   - Run migrations before service updates only when they are backward compatible; otherwise design an explicit expand/contract release.
   - Scan built static assets for forbidden internal tokens when frontend build-time variables are involved.
   - Record the deployed artifact tag in logs, release notes, GitOps commits, or deployment summaries.

## Patterns To Reuse

Use direct AWS deployment when the app already has ECS/S3 as the runtime target and GitHub Actions is the deployment authority. Read [GitHub Actions to AWS ECS/S3](references/github-actions-aws-ecs.md) for a complete dev/staging/prod example.

Use Kubernetes GitOps when Helm values are the desired state and ArgoCD owns cluster mutation. Read [Source Patterns](references/source-patterns.md) for the extracted Bitbucket/Kubernetes pattern.

Use a pipeline migration approach when converting from Bitbucket or Azure DevOps to GitHub Actions: preserve the environment contract first, then translate platform syntax. Keep artifact naming, target environment mapping, secret ownership, and deployment authority stable.

## Design Rules

- Prefer OIDC federation from GitHub Actions to AWS IAM over static AWS access keys.
- Put application runtime secrets in AWS Secrets Manager/SSM or Kubernetes secrets, not in GitHub unless the pipeline itself must read them.
- Pass private dependency tokens to Docker builds with BuildKit secret mounts.
- Keep public frontend values explicit and environment scoped; treat them as configuration, not secrets.
- Separate validation from deployment. PRs validate; branch/tag/release events deploy.
- Make environment names boring and consistent across CI, cloud resources, DNS, and code: `dev`, `staging`, `production`.
- Document the target infra contract next to the pipeline: region, account, registry, cluster/service, S3 bucket, task definition or Helm values, migration behavior, and required secrets.

## Reference Loading

- Read `references/github-actions-aws-ecs.md` when the user asks for GitHub Actions targeting AWS, ECS, S3, ECR, OIDC, or dev/staging/prod deployment.
- Read `references/source-patterns.md` when the user asks to reason from existing Bitbucket Pipelines, Azure DevOps, Kubernetes GitOps, Helm, ArgoCD, or ECS task-definition examples.
