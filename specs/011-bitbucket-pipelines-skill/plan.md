# Implementation Plan: Bitbucket Pipelines Skill

**Branch**: `011-bitbucket-pipelines-skill` | **Date**: `2025-05-11` | **Spec**: `specs/011-bitbucket-pipelines-skill/spec.md`
**Input**: Feature specification from `/specs/011-bitbucket-pipelines-skill/spec.md`

## Summary

This skill provides comprehensive documentation for Bitbucket Pipelines CI/CD based on official Atlassian documentation. The plan covers understanding bitbucket-pipelines.yml configuration, using pipes for third-party integrations, managing variables/secrets, and viewing pipeline results.

## Technical Context

**Language/Version**: Documentation (Markdown, YAML)  
**Primary Dependencies**: Official Bitbucket documentation, pipes from Atlassian  
**Storage**: Resources stored in local `resources/` folder  
**Testing**: Documentation review and validation  
**Target Platform**: Bitbucket Cloud (documentation reference)  
**Project Type**: documentation (skill)  
**Performance Goals**: Documentation under 200 lines  
**Constraints**: Must reference external resources, must be readable  
**Scale/Scope**: Bitbucket Pipelines documentation with references

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

[Gates: Documentation skill - No repository architecture constraints apply]

## Project Structure

### Documentation (this feature)

```text
specs/011-bitbucket-pipelines-skill/
├── plan.md               # This file (/speckit.plan command output)
├── research.md           # Phase 0 output (/speckit.plan command)
├── data-model.md         # Phase 1 output (/speckit.plan command)
├── quickstart.md         # Phase 1 output (/speckit.plan command)
└── tasks.md              # Phase 2 output (/speckit.tasks command)

skills/
└── bitbucket-pipelines/
    ├── SKILL.md          # Main skill file (< 200 lines)
    └── resources/        # Supporting documentation
        ├── get-started.md
        ├── configure-first-pipeline.md
        ├── what-are-pipes.md
        ├── variables-secrets.md
        ├── view-pipeline.md
        └── dependencies.md
```

### Implementation Approach

For documentation-only skills:

- Extract content from official documentation sites
- Summarize key concepts concisely (< 200 lines)
- Organize supporting materials in `resources/` folder
- Create references between documentation and sources

## Phase 0: Research (Completed)

Research completed from official Atlassian Bitbucket documentation:

**Research Findings:**

1. bitbucket-pipelines.yml defines pipelines at repository root
2. UI wizard provides templates for common use cases
3. Pipes enable third-party integrations (AWS, Azure, etc.)
4. Variables/secrets can be scoped at workspace, repository, or deployment level
5. Pipeline results view shows status, logs, and artifacts

## Phase 1: Design & Contracts

### Deliverables Created:

1. **SKILL.md**: Main skill documentation (< 200 lines)
2. **resources/**: Supporting documentation files

### Structure Decision

Documentation organized as:

- Main skill file (SKILL.md) for quick reference
- Resource files in resources/ for detailed documentation
- Cross-references between files for navigation

## Complexity Tracking

This is a documentation skill - complexity is minimal.

| Aspect     | Complexity | Notes                           |
| ---------- | ---------- | ------------------------------- |
| Content    | Low        | Based on existing documentation |
| Structure  | Low        | Simple documentation files      |
| References | Medium     | Need to link to Bitbucket docs  |

**Conclusion**: No complex architecture needed for documentation-only skill.
