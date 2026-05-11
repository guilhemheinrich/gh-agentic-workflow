# Quickstart: Bitbucket Pipelines

**Branch**: `011-bitbucket-pipelines-skill` | **Date**: `2025-05-11`

## Getting Started with Bitbucket Pipelines

### Prerequisites

- Bitbucket Cloud account
- At least one repository in your workspace

### Step 1: Create Your First Pipeline

1. Go to your repository
2. Select **Pipelines** in the left sidebar
3. Click **Create your first pipeline**
4. Choose a template RECOMMENDED for your tech stack
5. Edit the YAML in the editor

### Step 2: Add Pipes (Optional)

For third-party integrations:

1. Hover over steps panel
2. Select a pipe (e.g., AWS S3 Deploy)
3. Copy the pipe snippet
4. Paste into the `script` section
5. Add your variable values

Example:

```yaml
- pipe: atlassian/aws-s3-deploy:0.2.2
  variables:
    AWS_REGION: "us-east-1"
    S3_BUCKET: "my-bucket"
```

### Step 3: Add Variables

1. Go to **Repository settings** > **Pipelines** > **Repository variables**
2. Add name, value, and secure checkbox if needed
3. Access in YAML as `$VARIABLE_NAME`

### Step 4: Run and View Pipeline

1. Push to trigger pipeline
2. View status in **Pipelines** section
3. Click step to see logs
4. Rerun failed steps or entire pipeline

### Next Steps

- [Configure your first pipeline](resources/bitbucket-pipelines/get-started.md)
- [Learn about pipes](resources/bitbucket-pipelines/pipes.md)
- [Manage variables and secrets](resources/bitbucket-pipelines/variables.md)

## Validation

- Pipeline runs successfully
- Logs visible in Pipeline history
- Steps show correct status (Successful, Failed, etc.)
