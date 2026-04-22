# Quickstart: Release and Versioning Standards

## What This Delivers

Three artifacts for the `gh-agentic-workflow` agent skill library:

1. **`skills/app-version-surface/SKILL.md`** — Organization-wide standard for exposing and displaying application version metadata.
2. **`skills/semantic-release-js-ts-pipeline/SKILL.md`** — Standard release automation pipeline for JavaScript/TypeScript projects.
3. **`commands/spec-release-and-versioning.md`** — Command that produces Speckit specifications for versioning needs.

## How to Use

### Skill 1: App Version Surface

When building or reviewing a project's version display:

1. Read `skills/app-version-surface/SKILL.md`
2. Follow the canonical JSON contract for your component type
3. Choose the appropriate ingestion mode (build-time, runtime, hybrid)
4. Implement the UI display rules
5. Use the implementation checklist to verify completeness

### Skill 2: Semantic Release Pipeline

When setting up release automation for a JS/TS project:

1. Read `skills/semantic-release-js-ts-pipeline/SKILL.md`
2. Identify your project type (application, npm package, monorepo)
3. Copy the appropriate `.releaserc` reference configuration
4. Configure your CI pipeline (dry-run on PR, release on merge)
5. Ensure conventional commits are enforced

### Command: `/spec-release-and-versioning`

When a team needs to adopt the versioning standard:

```
/spec-release-and-versioning We need to show app version in the admin panel and automate releases for our Node.js API
```

The command produces a complete Speckit specification that an implementer agent can execute.

## Verification

After implementation, verify:

- [ ] `skills/app-version-surface/SKILL.md` exists with YAML frontmatter and all required sections
- [ ] `skills/semantic-release-js-ts-pipeline/SKILL.md` exists with YAML frontmatter and all required sections
- [ ] `commands/spec-release-and-versioning.md` exists with YAML frontmatter and all required sections
- [ ] Both skills follow the repository's existing SKILL.md format (see `skills/sonarqube-config/SKILL.md` for reference)
- [ ] The command follows the repository's existing command format (see `commands/push.md` for reference)
