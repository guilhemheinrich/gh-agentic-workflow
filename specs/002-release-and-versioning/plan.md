# Implementation Plan: Release and Versioning Standards

**Branch**: `002-release-and-versioning` | **Date**: 2026-04-22 | **Spec**: [spec.md](./spec.md)

## Summary

Deliver two reusable agent skills and one command file for the `gh-agentic-workflow` library. The skills codify organization-wide standards for application version surfacing and JS/TS semantic-release pipelines. The command produces Speckit specifications from versioning requirements.

## Technical Context

**Language/Version**: Markdown (skill/command definitions)
**Primary Dependencies**: None (documentation artifacts, no runtime code)
**Project Type**: Agent skill library (Cursor-compatible SKILL.md / command.md files)
**Target Platform**: Any JS/TS project, any CI provider, any frontend/backend framework

## Architecture Decision

All three deliverables are **documentation-as-code** artifacts following the existing `gh-agentic-workflow` repository conventions:
- Skills are directories under `skills/` with a `SKILL.md` file following the YAML frontmatter + markdown body format.
- Commands are markdown files under `commands/` with a YAML frontmatter + markdown body format.
- No runtime code is produced — the skills contain reference configurations, JSON schemas, and implementation checklists that agents consume to generate project-specific code.

## Technology Stack

| Component | Technology | Rationale |
|---|---|---|
| Skill format | Markdown + YAML frontmatter | Existing convention in the repository |
| Version contract | JSON Schema (embedded in skill) | Machine-readable, framework-agnostic |
| Release tool | semantic-release | Industry standard for JS/TS release automation |
| Commit convention | Conventional Commits | Required by semantic-release, already enforced by project rules |

## Project Structure

```text
skills/
  app-version-surface/
    SKILL.md                          # Skill 1 — version metadata standard
  semantic-release-js-ts-pipeline/
    SKILL.md                          # Skill 2 — release automation standard
commands/
  spec-release-and-versioning.md      # Command — Speckit spec generator
specs/
  002-release-and-versioning/
    prompt.md
    spec.md
    plan.md
    tasks.md
    stats.md
    quickstart.md
```

## Implementation Strategy

### Phase 1: Foundation — Spec Artifacts

Create the spec folder with all planning documents (prompt, spec, plan, tasks, stats, quickstart). This is the current `/specify` phase.

### Phase 2: Skill 1 — `app-version-surface`

Create `skills/app-version-surface/SKILL.md` containing:
- YAML frontmatter with name and description
- Canonical JSON version contract (mandatory + optional fields)
- Display format standard (`version+commit`)
- UI display rules (Level 1: user-visible, Level 2: technical panel)
- Three ingestion modes (build-time, runtime endpoint, hybrid)
- Aggregated version contract for multi-component apps
- Implementation checklist (application project)
- Security and observability checklist
- Anti-patterns

### Phase 3: Skill 2 — `semantic-release-js-ts-pipeline`

Create `skills/semantic-release-js-ts-pipeline/SKILL.md` containing:
- YAML frontmatter with name and description
- Commit convention mapping table
- Plugin matrix (minimum viable, standard app, npm package, opt-in)
- Reference `.releaserc` configurations for each project type
- CI pipeline architecture (dry-run on PR, release on merge)
- Branch governance (main, next, beta)
- Integration with version surfacing skill
- Implementation checklist
- Anti-patterns

### Phase 4: Command — `/spec-release-and-versioning`

Create `commands/spec-release-and-versioning.md` containing:
- YAML frontmatter with name and description
- Command behavior and usage examples
- Speckit spec template with all required sections
- Reference to both skills
- Prompt templates (standard and directive variants)

## Dependencies

- Existing skill format convention (observed from `sonarqube-config`, `git-commit`)
- Existing command format convention (observed from `commit.md`, `push.md`)
- SemVer specification for build metadata format
- semantic-release documentation for plugin configuration
- Speckit methodology for spec structure
