# Variables and Secrets

**Source**: [Atlassian Support](https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/)

Variables are configured as environment variables in the build container, accessed as `$VARIABLE_NAME`.

## Default Variables

Pipelines provides default variables available for builds:

| Variable               | Description                       |
| ---------------------- | --------------------------------- |
| CI                     | Default `true` when pipeline runs |
| BITBUCKET_BUILD_NUMBER | Unique build identifier           |
| BITBUCKET_COMMIT       | Commit hash that triggered build  |
| BITBUCKET_BRANCH       | Source branch (not for tags)      |
| BITBUCKET_TAG          | Build tag (not for branches)      |
| BITBUCKET_REPO_SLUG    | URL-friendly repository name      |
| BITBUCKET_WORKSPACE    | Workspace name                    |

See full list for [default variables](https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/#Reference-variables-in-your-pipeline).

## User-Defined Variables

You can add, edit, or remove variables at:

1. **Workspace level**: All repos in workspace (admin only)
2. **Repository level**: Specific to one repo (admin only)
3. **Deployment environment level**: Specific to environment

### Workspace Variables

Accessed from any repo in workspace. Must be workspace administrator.

### Repository Variables

Accessed by anyone with write access. Repository admin manages.

### Shared Pipeline Variables

Share variable value from step to subsequent steps:

```yaml
- step:
    script:
      - echo "VARIABLE_NAME=my-value" >> $BITBUCKET_PIPELINES_VARIABLES_PATH
    output-variables:
      - VARIABLE_NAME
```

### Deployment Variables

Only work within deployment steps:

```yaml
- step:
    name: Deploy to Test
    deployment: Test
    script:
      - echo $DEPLOYMENT_VARIABLE
```

## Secure Variables

Secure variables are encrypted, their values hidden in build logs:

```yaml
pipelines:
  default:
    - step:
        script:
          - expr 10 / $MY_HIDDEN_NUMBER
```

Value appears as `$MY_HIDDEN_NUMBER` in logs.

## Variables in YAML

Template variables use `${{ VARIABLE_NAME }}` syntax:

```yaml
image: ${{IMAGE_NAME}}
pipelines:
  default:
    - step:
        name: "Pipeline in ${{BITBUCKET_REPO_SLUG}}"
```

Supported: Workspace, Repository, Custom Pipeline, Certain Default variables.
