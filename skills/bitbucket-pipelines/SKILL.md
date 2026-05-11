---
name: bitbucket-pipelines
description: BitBucket Pipelines CI/CD YAML configuration reference
version: 1.0.0
language: en-US
---

# BitBucket Pipelines

Reference for `bitbucket-pipelines.yml` CI/CD configuration.

## Basic Structure

```yaml
image: atlassian/default-image:3

pipelines:
  default:
     - step: name: Build script: - echo "Build"
  branches:
     main:
       - step: name: Deploy script: - deploy
  pull-requests:
     '**':
       - step: name: Test script: - run-tests
```

## Global `options` (all pipelines)

```yaml
options:
  # Docker service enabled for all steps
  docker: true
  # Max step runtime (minutes, default=120, max=720)
  max-time: 60
  # Resource allocation (1x=4GB RAM, 2x=8GB, 4x=16GB...)
  size: 2x
  # Runtime config
  runtime:
    cloud:
      atlassian-ip-ranges: true
      arch: arm
```

## Build/Deploy Templates

### Node.js CI/CD

```yaml
image: atlassian/default-image:3
definitions:
  caches:
    - node_modules: ~/.npm
pipelines:
  default:
     - step:
        name: Build & Test
        caches:
          - node_modules
        script:
           - npm install
           - npm run build
```

### Docker Service for DB

```yaml
definitions:
  services:
    docker:
      image: docker:20.10
    mysql:
      image: mysql:5.7
```

## Pipes (Third-Party Integrations)

```yaml
- pipe: atlassian/aws-s3-deploy:0.2.2
  variables:
    AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION: 'us-east-1'
    S3_BUCKET: 'my-bucket'
```
See [Pipes Repository](https://bitbucket.org/product/features/pipelines/integrations)

## Variables

Reference in scripts: `$VARIABLE_NAME`
Template in YAML: `${{VARIABLE_NAME}}`

Types: Workspace, Repository, Deployment (secured)

## Parallel Steps

```yaml
parallel:
  steps:
     - step: name: Test batch 1 script: - tests --batch 1
     - step: name: Test batch 2 script: - tests --batch 2
```

## Caches

```yaml
definitions:
  caches:
    - node_modules: ~/.npm
pipelines:
  default:
     - step:
        caches:
          - node_modules
```

## Dependencies

- [YAML Configuration Reference](https://support.atlassian.com/bitbucket-cloud/docs/configure-bitbucket-pipelinesyml/)
- [Global Options](https://support.atlassian.com/bitbucket-cloud/docs/global-options/)
- [Step Options](https://support.atlassian.com/bitbucket-cloud/docs/step-options/)
- [Variables & Secrets](https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/)
- [Pipe Integrations](https://bitbucket.org/product/features/pipelines/integrations)
