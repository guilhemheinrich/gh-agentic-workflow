# Feature Specification: Release and Versioning Standards

**Feature Branch**: `002-release-and-versioning`
**Created**: 2026-04-22
**Status**: Draft
**Input**: User description: "Create skills and command for standardizing application version surfacing, semantic-release JS/TS pipeline, and a Speckit command to produce versioning specs"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Agent Generates Version Metadata Infrastructure for a New Project (Priority: P1)

A developer asks the AI agent to add version surfacing to a project. The agent reads the `app-version-surface` skill and generates: a version metadata endpoint for the backend, build-time version injection for the frontend, and a UI component displaying the canonical format.

**Why this priority**: Without a standard version contract, teams invent ad-hoc formats. This is the foundational use case that ensures every component in the organization follows the same data shape and display rules.

**Independent Test**: Ask the agent to add version surfacing to a blank NestJS + Vite project. Verify the generated code exposes the canonical JSON contract, the frontend injects version at build time, and the UI shows `version+commit`.

**Acceptance Scenarios**:

1. **Given** a project with the skill installed, **When** the developer asks "add version surfacing", **Then** the agent generates a `/version` endpoint returning the canonical JSON contract with all 6 mandatory fields.
2. **Given** a frontend SPA build, **When** the agent configures build-time injection, **Then** `displayVersion`, `version`, `gitCommit`, and `buildTime` are injected from CI environment variables or Git metadata.
3. **Given** a multi-component application (frontend + backend), **When** the frontend fetches versions from both components, **Then** it displays a "Technical Information" panel showing both component versions in the standard format.
4. **Given** a backend component is unreachable, **When** the UI attempts to fetch its version, **Then** it displays `unavailable` rather than a misleading value.

---

### User Story 2 — Agent Configures semantic-release for a JS/TS Application (Priority: P1)

A developer asks the agent to set up automated releases for a TypeScript application that is not published to npm. The agent reads the `semantic-release-js-ts-pipeline` skill and generates the correct `.releaserc` configuration, CI pipeline steps, and commit convention documentation.

**Why this priority**: Release automation is the mechanism that produces the version numbers consumed by the version surfacing skill. Without it, version metadata must be managed manually, which defeats the standard.

**Independent Test**: Set up a test repository with conventional commits. Run `semantic-release --dry-run`. Verify the correct next version is calculated, release notes are generated, and no `CHANGELOG.md` is committed.

**Acceptance Scenarios**:

1. **Given** a JS/TS application project (not npm package), **When** the agent configures semantic-release, **Then** the configuration uses `commit-analyzer` + `release-notes-generator` + optionally the GitHub/GitLab release plugin, without `@semantic-release/changelog` or `@semantic-release/git`.
2. **Given** a commit history containing `feat: add search`, **When** semantic-release runs, **Then** the minor version is incremented and a Git tag is created.
3. **Given** a commit with `BREAKING CHANGE:` footer, **When** semantic-release runs, **Then** the major version is incremented.
4. **Given** the CI pipeline configuration, **When** a PR is opened, **Then** `semantic-release --dry-run` executes and reports the projected next version without creating a tag.

---

### User Story 3 — Agent Configures semantic-release for an npm Package (Priority: P2)

A developer asks the agent to set up releases for a private npm library. The agent adds `@semantic-release/npm` to the pipeline and configures the correct publish workflow.

**Why this priority**: npm packages are the second most common project type. The skill must handle both application and library use cases with explicit differentiation.

**Independent Test**: Configure a test npm package, make a `fix:` commit, run semantic-release. Verify the patch version is bumped in `package.json` and a tag is created.

**Acceptance Scenarios**:

1. **Given** an npm package project, **When** the agent configures semantic-release, **Then** it includes `@semantic-release/npm` in the plugin list.
2. **Given** a `fix:` commit on an npm package, **When** semantic-release runs, **Then** the patch version is incremented and `package.json` version is updated during the release flow.
3. **Given** a project where `CHANGELOG.md` commit is explicitly requested, **When** the agent configures the pipeline, **Then** it adds `@semantic-release/changelog` and `@semantic-release/git` with a clear comment explaining this is opt-in.

---

### User Story 4 — Developer Uses `/spec-release-and-versioning` to Produce a Speckit Spec (Priority: P2)

A developer runs the `/spec-release-and-versioning` command with a description of their versioning needs. The agent produces a complete Speckit specification covering version metadata contracts, UI rules, CI/CD governance, and semantic-release configuration.

**Why this priority**: The command is the entry point for teams adopting the standard. It translates a potentially vague need into a structured, actionable specification.

**Independent Test**: Run the command with "we need to show app version in the admin panel and automate releases for our Node.js API". Verify the output is a complete Speckit spec with all required sections.

**Acceptance Scenarios**:

1. **Given** a user invokes `/spec-release-and-versioning` with a description, **When** the command executes, **Then** it produces a Speckit spec with sections: Problem, Goals, Non-Goals, Constraints, Decisions, Spec, Acceptance Criteria, Risks, Migration Plan, Open Questions.
2. **Given** the generated spec, **When** reviewed, **Then** it includes the canonical JSON version contract, UI display rules, and the recommended semantic-release configuration for the project type.
3. **Given** the generated spec references both skills, **When** an implementer agent reads it, **Then** it can follow the spec to implement the full solution without additional context.

---

### Edge Cases

- What happens when a project uses a non-conventional commit format?
  - The skill documents that conventional commits are a prerequisite for semantic-release. Projects not using them must adopt them first or use a custom `commit-analyzer` configuration.
- What happens in a monorepo with multiple packages?
  - The skill documents monorepo as a supported variant with known limitations. It recommends workspace-aware tools but does not fully specify monorepo support.
- What if the Git commit hash is unavailable at build time?
  - The skill specifies that `gitCommit` should fall back to `unknown` and documents how to ensure Git metadata is available in CI environments.
- What if a component has no semver version (e.g., a worker with only a commit hash)?
  - The `version` field should use `0.0.0` as a sentinel value, and `displayVersion` should reflect the commit hash only: `0.0.0+abc1234`.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The `app-version-surface` skill MUST define a canonical JSON contract for component version metadata with 6 mandatory fields: `component`, `displayVersion`, `version`, `gitCommit`, `buildTime`, `environment`.
- **FR-002**: The skill MUST define optional fields: `releaseTag`, `repository`, `branch`, `deploymentId`, `apiCompatibility`, `statusEndpoint`.
- **FR-003**: The skill MUST specify UI display rules at two levels: user-visible (footer/about) and technical panel (all components).
- **FR-004**: The skill MUST document three ingestion modes: build-time injection, runtime endpoint, and hybrid (recommended default).
- **FR-005**: The skill MUST define an aggregated version contract for multi-component applications.
- **FR-006**: The `semantic-release-js-ts-pipeline` skill MUST define configurations for three project types: application (no npm), npm package, and monorepo (documented limitations).
- **FR-007**: The semantic-release skill MUST specify the commit convention mapping: `feat:` → minor, `fix:` → patch, `BREAKING CHANGE:` → major.
- **FR-008**: The semantic-release skill MUST recommend minimum viable plugins (`commit-analyzer`, `release-notes-generator`) and identify opt-in plugins (`changelog`, `git`).
- **FR-009**: The semantic-release skill MUST define CI governance: dry-run on PR, release on merge to allowed branches, branch configuration.
- **FR-010**: The `/spec-release-and-versioning` command MUST produce a complete Speckit specification with all standard sections.
- **FR-011**: The command MUST reference both skills and integrate their standards into the generated spec.
- **FR-012**: The version display format MUST be `<version>+<gitCommit>` following SemVer build metadata convention.

### Key Entities

- **VersionMetadata**: The canonical data shape for a single component's version information (6 mandatory + optional fields).
- **AggregatedVersionMetadata**: Wrapper containing `application` name, top-level `displayVersion`, and an array of component `VersionMetadata`.
- **SemanticReleaseConfig**: The `.releaserc` configuration object defining branches, plugins, and options.
- **SpecReleaseSpec**: The Speckit specification document produced by the command.

## Success Criteria *(mandatory)*

- **SC-001**: Any team following the `app-version-surface` skill can expose version metadata for any component within 2 hours of work.
- **SC-002**: Support teams can identify the exact build of any deployed component by reading the UI version display, without needing access to CI/CD tools.
- **SC-003**: The version displayed in the UI matches the Git tag, Sentry release, and log metadata — there is a single source of truth.
- **SC-004**: A developer can configure semantic-release for a new JS/TS project within 30 minutes using the skill as a guide.
- **SC-005**: Zero manual version bumping is required after semantic-release is configured — the CI pipeline handles it automatically.
- **SC-006**: The `/spec-release-and-versioning` command produces a spec that an implementer agent can execute without requesting additional clarification in at least 80% of cases.
- **SC-007**: Both skills are stack-agnostic — they do not impose a specific frontend framework, backend framework, or CI provider.
