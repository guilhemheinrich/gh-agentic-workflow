# Research: Bitbucket Pipelines

**Branch**: `011-bitbucket-pipelines-skill` | **Date**: `2025-05-11`

## Overview

This research consolidates findings from official Atlassian Bitbucket Pipelines documentation to support the skill creation.

### Key Sources Consulted

| Source                   | URL                                                                                              | Key Takeaway                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| Get Started              | https://support.atlassian.com/bitbucket-cloud/docs/get-started-with-bitbucket-pipelines/         | Pipelines is integrated CI/CD service for Bitbucket Cloud   |
| Configure First Pipeline | https://support.atlassian.com/bitbucket-cloud/docs/configure-your-first-pipeline/                | UI wizard or YAML editor for pipeline configuration         |
| What are Pipes           | https://support.atlassian.com/bitbucket-cloud/docs/what-are-pipes/                               | Pipes provide third-party integration via Docker containers |
| Variables & Secrets      | https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/                        | Variables scoped at workspace/repo/deployment levels        |
| View Pipeline            | https://support.atlassian.com/bitbucket-cloud/docs/view-your-pipeline/                           | Pipeline history and log viewing interface                  |
| Dependencies             | https://support.atlassian.com/bitbucket-cloud/docs/specify-dependencies-in-your-pipelines-build/ | Docker services or build script for dependencies            |

### Major Findings

**1. Pipeline Configuration**

- bitbucket-pipelines.yml at repository root
- Two configuration methods: UI wizard or direct YAML editing
- Templates available for common use cases (NodeJS, Java, .NET, cloud providers)

**2. Pipes**

- Pre-configured scripts in Docker containers
- Example: AWS S3 Deploy pipe uploads build contents
- Pipes use semantic versioning (atlassian/aws-s3-deploy:0.2.2)

**3. Variables**

- Workspace level: All repos in workspace
- Repository level: Specific to one repo
- Deployment level: Specific to deployment environments
- Secure variables masked in build logs

**4. Pipeline Viewing**

- Pipeline history with filtering options
- Log view with expandable sections
- Rerun capability for failed pipelines

**5. Dependencies**

- Run as Docker services (recommended)
- Install via build script (apt-get for Debian/Ubuntu)
- Create custom Docker images

### Decisions Made

1. **Approach**: Use both UI wizard and YAML editing approaches
2. **Documentation**: Keep under 200 lines as requested
3. **Resources**: Reference in `resources/` folder for detailed docs
4. **Structure**: Simple documentation-only skill

### Alternative Approaches Considered

- **Only YAML approach**: Rejected - UI wizard is easier for beginners
- **Only Pipes approach**: Rejected - Pipes are optional
- **Include code examples**: Rejected - Documentation-only skill

## Conclusion

Bitbucket Pipelines provides flexible CI/CD automation integrated with Bitbucket Cloud. The skill will document key concepts while maintaining conciseness (< 200 lines).
