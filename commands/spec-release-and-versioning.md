---
name: spec-release-and-versioning
description: >-
  Transform a versioning or release-related need into a full Speckit specification.
  Covers application version metadata contracts, UI display rules, semantic-release
  CI/CD governance, and migration planning. References the app-version-surface and
  semantic-release-js-ts-pipeline skills.
---

# `/spec-release-and-versioning` — Version & Release Spec Generator

This command takes a business or technical need related to **application versioning**, **version display**, or **release automation** and produces a **complete Speckit specification** that implementer agents can execute. The output is structured for Spec-Kit workflows: requirements, decisions, risks, and migration are explicit so planning and implementation stay aligned with organizational standards.

**Execution note for agents**: In this repository, all tooling commands (Node, npm, Python, pip, and similar) must be run **inside Docker**, never on the host machine, unless a project-specific runbook says otherwise.

## Usage

```
/spec-release-and-versioning We need to show the app version in the admin panel and automate releases for our Node.js API
/spec-release-and-versioning Standardize version display across our 3 frontend apps and 2 backend services
/spec-release-and-versioning Set up semantic-release for our private npm library with pre-release channels
```

## Behavior

When invoked, the command must direct the agent to:

1. **Reformulate the problem statement** — clarify intent, actors, and success from the user’s text.
2. **Identify the scope** — which components (frontends, APIs, workers, packages) and which project types (application deployables vs. npm libraries).
3. **List constraints and non-goals** — what is in scope, what is explicitly excluded, and org-wide rules (e.g. display format, mandatory metadata fields).
4. **Propose structural decisions** — grounded in the two referenced skills (`app-version-surface`, `semantic-release-js-ts-pipeline`): version contract, ingestion mode, release automation, and plugin set.
5. **Produce a complete Speckit specification** — using the **Speckit Output Template** below (fill all sections; no placeholder-only stubs).
6. **Include** acceptance criteria, risks, open questions, and a phased migration plan.

## Referenced Skills

The agent **must** load and apply these skills when generating the spec:

| Skill | Use for |
| ----- | -------- |
| **`app-version-surface`** | Version metadata contract, UI display rules, ingestion modes (build-time, runtime, hybrid). |
| **`semantic-release-js-ts-pipeline`** | Release automation, CI/CD governance, branch strategy, dry-run on PRs, plugin configuration. |

Paths (repo-relative): `skills/app-version-surface/SKILL.md` and the skill for semantic-release in JS/TS (e.g. `skills/semantic-release-js-ts-pipeline/SKILL.md` or the project’s canonical path if relocated).

## Speckit Output Template

The generated spec **must** follow this structure (replace bracketed parts with project-specific content):

```markdown
# Spec: [Title derived from user input]

**Date**: [YYYY-MM-DD]
**Status**: Draft
**Input**: [User's original description]

## Problem

[Reformulated problem statement — why is this needed]

## Goals

- [Goal 1]
- [Goal 2]
- ...

## Non-Goals

- [Explicit exclusion 1]
- [Explicit exclusion 2]
- ...

## Constraints

- Standard display format: `<version>+<gitCommit>`
- Mandatory fields: component, displayVersion, version, gitCommit, buildTime, environment
- Must be stack-agnostic
- [Project-specific constraints]

## Decisions

### D1: Version Display Format
Adopt `<version>+<gitCommit>` (e.g., `2.4.1+5f2c9ab`) per organization standard.

### D2: Canonical Version Contract
Use the 6-mandatory-field JSON contract from the `app-version-surface` skill.

### D3: Ingestion Mode
[Recommend build-time, runtime, or hybrid based on the project description]

### D4: Release Automation
[Recommend semantic-release configuration based on the project type]

### D5: Plugin Selection
[Recommend plugin set based on whether it's an application or npm package]

## Specification

### Version Metadata Contract
[Include the canonical JSON contract with mandatory and optional fields]

### UI Display Rules
[Include Level 1 and Level 2 display rules adapted to the project]

### CI/CD Pipeline
[Include semantic-release configuration, branch strategy, dry-run policy]

### Version Surfacing Integration
[How the release version flows into build metadata and runtime endpoints]

## Acceptance Criteria

- [ ] Every deployable component exposes version metadata with all mandatory fields
- [ ] UI displays version in `version+commit` format
- [ ] Multi-component applications show at least frontend + backend versions
- [ ] Displayed metadata matches logs and observability tools
- [ ] A `feat:` commit triggers a minor version bump
- [ ] A `fix:` commit triggers a patch version bump
- [ ] Release notes are generated automatically
- [ ] Dry-run executes on PRs
- [ ] [Project-specific criteria]

## Risks

- [Risk 1: description and mitigation]
- [Risk 2: description and mitigation]

## Migration Plan

### Phase 1: Foundation
[Steps to adopt the standard incrementally]

### Phase 2: Rollout
[Steps to apply across components]

### Phase 3: Enforcement
[Steps to ensure ongoing compliance]

## Open Questions

- [Question 1]
- [Question 2]

## Appendix A: Application Project Implementation Checklist

- [ ] CI pipeline injects Git metadata (commit hash, tag, build time)
- [ ] Build process generates version file or environment variables
- [ ] Backend exposes `/version` endpoint returning canonical contract
- [ ] Frontend reads injected metadata at build time
- [ ] UI component displays version in standard format
- [ ] Aggregation endpoint for multi-component apps
- [ ] Sentry/observability configured with same version format
- [ ] semantic-release configured with correct project type
- [ ] Conventional commits enforced
- [ ] CI dry-run configured on PRs

## Appendix B: npm Package Implementation Checklist

- [ ] `@semantic-release/npm` plugin configured
- [ ] NPM_TOKEN secret configured in CI
- [ ] `.releaserc.json` uses npm package configuration
- [ ] Package version updated during release flow
- [ ] Pre-release channels configured if needed (next, beta)
- [ ] Access level set correctly (public or restricted)
```

## Standard Prompt Template

The agent should inject the following (or a close paraphrase) into context when producing the spec:

```
You must produce a Speckit specification to standardize the management and exposure
of application versions, and the automation of releases in the JavaScript/TypeScript
ecosystem.

Context:
- We want a uniform way to expose and display versions of application components:
  frontend, backend, worker, gateway, and other runtime components.
- We want a standard format that is readable by support and usable by development
  and operations teams.
- We want to standardize the use of semantic-release in JS/TS projects for
  automating version calculation, release tags, and release notes.
- The solution must be framework and platform agnostic, while imposing a shared
  data contract and architecture rules.

Reference skills:
- app-version-surface: version metadata contract, UI rules, ingestion modes
- semantic-release-js-ts-pipeline: release automation, plugins, CI/CD governance

Mandatory standards:
- Display format: <version>+<gitCommit>
- Mandatory fields: component, displayVersion, version, gitCommit, buildTime, environment
- Multi-component apps must aggregate component versions
- semantic-release recommended for JS/TS with conventional commits
- changelog and git plugins not imposed by default
- Compatible with observability and support workflows

Produce the complete spec directly.
```

## Directive Variant Prompt

Use this shorter prompt when the user wants **minimal framing** and a **direct** specification:

```
Create an executable, unambiguous Speckit specification.
Do not produce a framing note — produce a real specification usable by code agents.

Subject:
Organization standard for:
1. Exposure and display of application component versions
2. Use of semantic-release in the JavaScript/TypeScript ecosystem

Imperative requirements:
- Standard display format: <version>+<gitCommit>
- Support for frontend, backend, worker, gateway components
- Explicit distinction between human-readable version, release tag, and exact commit
- Hybrid strategy: frontend build-time + backend runtime endpoint
- semantic-release recommended without imposing npm publish
- Committed changelog and release commit not required by default
- Spec must include canonical JSON contract, UI rules, CI/CD rules, acceptance criteria, and migration plan

Produce the final spec directly.
```

## Delegation

- **Read** `skills/app-version-surface/SKILL.md` and the **semantic-release JS/TS pipeline** skill before writing decisions and checklists.
- **Write** the final artifact as a Speckit-ready spec (markdown), suitable for `specs/[XXX]-<feature>/spec.md` or an equivalent project path.
- **Respect** Docker-only command execution for any implementation or validation steps the user later runs.
