# Feature Specification: Bitbucket Pipelines Skill

**Feature Branch**: `011-bitbucket-pipelines-skill`  
**Created**: `2025-05-11`  
**Status**: Draft  
**Input**: "scrape le contenu de https://support.atlassian.com/bitbucket-cloud/docs/get-started-with-bitbucket-pipelines/ pour rédigé un skill pour les pipelines bitbuckets. le SKILL.md doit faire moins de 200 lignes, et référencés les différentes ressources qui seront stocké à coté dans un dossier resources/"

## User Scenarios & Testing _(mandatory)_

This skill provides comprehensive documentation and guidance for Bitbucket Pipelines CI/CD automation.

### User Story 1 - Learn Bitbucket Pipelines Basics (Priority: P1)

**Goal**: Read and understand the core concepts of Bitbucket Pipelines from official Atlassian documentation.

**Why this priority**: Users need foundational knowledge before implementing pipelines.

**Independent Test**: Document can be read and understood without implementation.

**Acceptance Scenarios**:

1. **Given** a new developer, **When** they read the skill documentation, **Then** they understand how to create a bitbucket-pipelines.yml file
2. **Given** a team member, **When** they review the pipelines documentation, **Then** they know how to add dependencies and variables

### User Story 2 - Use Bitbucket Pipelines UI (Priority: P1)

**Goal**: Use the Bitbucket UI wizard to configure pipelines visually.

**Why this priority**: UI wizard is the easiest way for beginners to start.

**Independent Test**: User can configure a pipeline using Bitbucket UI.

**Acceptance Scenarios**:

1. **Given** a repository with code, **When** user clicks Pipelines > Create your first pipeline, **Then** they see available templates
2. **Given** a user selects a template, **When** they reach the YAML editor, **Then** they can modify the pipeline configuration

### User Story 3 - Configure Pipes and Variables (Priority: P2)

**Goal**: Use pipes for third-party integrations and manage variables/secrets.

**Why this priority**: Pipes and variables enable powerful integrations with cloud services.

**Independent Test**: User can deploy to AWS S3 using a pipe and secure variables.

**Acceptance Scenarios**:

1. **Given** a user wants to deploy to AWS, **When** they use the AWS S3 Deploy pipeline, **Then** they configure the deployment with pipes
2. **Given** a user needs to store secrets, **When** they add secure variables, **Then** those values are hidden in build logs

---

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: Skill MUST provide overview of Bitbucket Pipelines integration with Bitbucket Cloud
- **FR-002**: Skill MUST document the `bitbucket-pipelines.yml` configuration file format
- **FR-003**: Skill MUST explain how to configure pipelines using the Bitbucket UI wizard
- **FR-004**: Skill MUST reference pipes for third-party tool integrations
- **FR-005**: Skill MUST explain variables and secrets management
- **FR-006**: Skill MUST document how to view pipeline results and logs
- **FR-007**: Skill MUST reference dependencies installation in build containers
- **FR-008**: Skill MUST stay under 200 lines as specified

### Key Entities

- **bitbucket-pipelines.yml**: YAML configuration file at repository root
- **pipe**: Pre-configured scripts for third-party integrations (e.g., AWS, Azure)
- **variable**: Environment variable for build containers (can be secured/encrypted)
- **pipeline**: The CI/CD workflow defined in bitbucket-pipelines.yml
- **repository**: Bitbucket repository where pipelines run

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: Documentation complete and under 200 lines
- **SC-002**: All Bitbucket Pipelines concepts explained clearly
- **SC-003**: References include official documentation links
- **SC-004**: Resources folder created with supporting files

## Assumptions

- Users have Bitbucket Cloud accounts
- Users have at least one repository in their workspace
- Users can access the official Bitbucket documentation URLS
- This skill is for documentation only (not code implementation)
- The skill will reference resources stored in a `resources/` folder

---

## References (Resource Links)

- [Configure your first pipeline](https://support.atlassian.com/bitbucket-cloud/docs/configure-your-first-pipeline/)
- [What are pipes](https://support.atlassian.com/bitbucket-cloud/docs/what-are-pipes/)
- [Variables and secrets](https://support.atlassian.com/bitbucket-cloud/docs/variables-and-secrets/)
- [View your pipeline](https://support.atlassian.com/bitbucket-cloud/docs/view-your-pipeline/)
- [Specify dependencies in your pipelines build](https://support.atlassian.com/bitbucket-cloud/docs/specify-dependencies-in-your-pipelines-build/)
