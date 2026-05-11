# Data Model: Bitbucket Pipelines Concepts

**Branch**: `011-bitbucket-pipelines-skill` | **Date**: `2025-05-11`

## Core Entities

### 1. bitbucket-pipelines.yml

YAML configuration file stored at repository root.

**Fields**:

- `image`: Docker image for build container
- `definitions`: Cache and service container definitions
- `pipelines`: Pipeline start options (default, branches, pull requests)

**Example**:

```yaml
image: atlassian/default-image:3

pipelines:
  default:
    - step:
        script:
          - echo "Hello World!"
```

### 2. Pipe

Pre-configured Docker container for third-party tools.

**Structure**:

- `pipe`: Reference to pipe (e.g., `atlassian/aws-s3-deploy:0.2.2`)
- `variables`: Pipe configuration values

**Common Pipes**:

- AWS S3 Deploy (`atlassian/aws-s3-deploy`)
- Azure Deploy (`atlassian/azure-appservice-deploy`)
- GCP Deploy (`atlassian/google-cloud-storage-deploy`)

### 3. Variable

Environment variable for build containers.

**Scopes**:

- Workspace level (all repos in workspace)
- Repository level (specific to repo)
- Deployment level (specific to environment)

**Access**: `$VARIABLE_NAME` in scripts, `${VARIABLE_NAME}` in YAML

### 4. Pipeline

CI/CD workflow defined by bitbucket-pipelines.yml.

**Types**:

- `default`: Runs on push to default branch
- `branches`: Runs when specified branch is pushed
- `pull-requests`: Runs on PR creation/update

### 5. Step

Individual task within a pipeline.

**Components**:

- `name`: Descriptive name
- `image`: Optional Docker image
- `script`: Commands to run
- `caches`: Directories to cache
- `services`: Dependent containers

## Relationships

```
Repository
   │
   ├── bitbucket-pipelines.yml (configuration)
   │      │
   │      ├── pipelines (default/branches/pull-requests)
   │      │      │
   │      │      └── steps (individual tasks)
   │      │             │
   │      │             └── variables (from variables/secrets)
   │      │
   │      └── definitions (caches/services)
   │
   ├── Variables (workspace/repo/deployment)
   └── Pipes (third-party integrations)
```

## Reference

- [Configure your first pipeline](https://support.atlassian.com/bitbucket-cloud/docs/configure-your-first-pipeline/)
- [What are pipes](https://support.atlassian.com/bitbucket-cloud/docs/what-are-pipes/)
- [Variables and secrets](https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/)
