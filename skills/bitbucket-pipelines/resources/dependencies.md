# Specify Dependencies in Your Pipelines Build

**Source**: [Atlassian Support](https://support.atlassian.com/bitbucket-cloud/docs/specify-dependencies-in-your-pipelines-build/)

Builds run in Docker containers providing the build environment.

## Run Dependencies as Services (Recommended)

Define dependencies as additional services in the `definitions` section:

```yaml
definitions:
  services:
    docker:
      image: docker:20.10
```

Recommended for databases, external caches, etc.

## Install Dependencies Using Build Script

Install using build script in your `bitbucket-pipelines.yml`:

```yaml
image: maven:3.3.9
pipelines:
  default:
    - step:
        script:
          - apt-get update && apt-get install -y imagemagick libjmagick6-java
          - mvn package
```

For shared dependencies, use [caching](https://confluence.atlassian.com/bitbucket/caching-dependencies-895552876.html).

## Create Docker Images

Create custom Docker images with dependencies pre-installed. See [Using Docker images as build environments](https://confluence.atlassian.com/bitbucket/using-docker-images-as-build-environments-792298897.html).

## Validator

Check your `bitbucket-pipelines.yml` with the [online validator](https://bitbucket.org/product/pipelines/validator).
