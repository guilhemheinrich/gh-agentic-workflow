# What Are Pipes

**Source**: [Atlassian Support](https://support.atlassian.com/bitbucket-cloud/docs/what-are-pipes/)

Pipes provide a simple way to configure a pipeline, especially for third-party tools.

Just paste the pipe into the YAML file, supply key information, and automation handles the rest. You can add as many pipes as you like.

## How It Works

A pipe uses a script in a Docker container with commands from your YAML plus extras. The provided pipes are public and their source code is available.

## Example: AWS S3 Deploy Pipe

```yaml
- pipe: atlassian/aws-s3-deploy:0.2.2
  variables:
    AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION: "us-east-1"
    S3_BUCKET: "my-bucket-name"
    LOCAL_PATH: "build"
```

Add S3 bucket deployment by selecting the pipe, copying, and pasting into the script section.

## Using Pipes

### 1. Online Editor

1. Open `bitbucket-pipelines.yml` in the editor
2. Select the pipe needed
3. Copy and paste into `script` section
4. Add values in single quotes (un-comment optional variables)
5. Run your build

### 2. Manual Configuration

Add pipe details to your `bitbucket-pipelines.yml` file using any editor.

## Considerations

- Pipes use the Docker service (counted toward service limits)
- Pipes use semantic versioning (version updates possible)
- 0.x.y pipes may have breaking changes between minor versions

## Help

Follow the pipe's support instructions in its repository README or contact [Atlassian Community](https://community.atlassian.com/).
