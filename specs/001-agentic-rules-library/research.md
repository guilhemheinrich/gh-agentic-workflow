# Research: Agentic Rules Library

**Date**: 2026-04-05
**Branch**: `001-agentic-rules-library`

## R1: Cursor Rules File Format

**Decision**: Use `.mdc` (Markdown with frontmatter) files in `.cursor/rules/`, not plain `.md`.

**Rationale**: Cursor uses `.mdc` format which supports YAML frontmatter for controlling when rules activate. This enables auto-attach behavior via `globs` patterns (e.g., `["**/*.ts"]`) and `alwaysApply` flags. Plain `.md` files are read but lack activation control.

**Alternatives considered**:
- `.cursorrules` single file: Legacy format, no per-rule activation control.
- `.md` in `.cursor/rules/`: Supported but no frontmatter-driven activation.

**Frontmatter schema**:
```yaml
---
description: "What this rule covers"
alwaysApply: true | false
globs: ["**/*.ts", "**/*.tsx"]  # optional, for auto-attach rules
---
```

**Rule types available**:
1. **Always Apply** (`alwaysApply: true`): Every interaction
2. **Auto-attached** (`globs: [...]`): When editing matching files
3. **Agent-decided** (`alwaysApply: false` + description): Agent determines relevance
4. **Manual** (`alwaysApply: false`, no globs): Only when explicitly referenced with `@rule-name`

## R2: Rule Activation Strategy

**Decision**: Use a mixed strategy per rule:
- `architecture-overview.mdc`: `alwaysApply: true` (always available as architecture context)
- Rule 1-7 individual files: `alwaysApply: false` with descriptive `description` field (agent-decided). The overview file references them, so the agent loads specific rules on demand.

**Rationale**: Making all 8 files `alwaysApply: true` wastes context window tokens on every interaction. Agent-decided rules with good descriptions let Cursor load only the relevant rule(s) per task.

## R3: Skill Reference Mechanism

**Decision**: Use Markdown links with relative paths from the rule file to the skill: `[fp-ts Error Handling](../../skills/fp-ts-errors/SKILL.md)`.

**Rationale**: Cursor resolves relative file paths in rules. The agent can follow these links to load skill content when applying a rule. Absolute paths would break portability across machines.

**Skill-to-Rule mapping**:
| Rule | Skill References |
|------|-----------------|
| Rule 3 (Anti-Currying) | `fp-ts-pragmatic` (named params, pipe patterns) |
| Rule 4 (Pure Domain) | `fp-ts-errors` (typed errors with Either), `fp-ts-backend` (ReaderTaskEither for DI) |
| Rule 5 (Flat Orchestration) | `fp-ts-pragmatic` (pipe/flow), `fp-ts-async-practical` (TaskEither pipelines) |
| Rule 6 (Typed Boundaries) | `fp-ts-validation` (validation with error accumulation) |

## R4: Constitution Content

**Decision**: Replace the template constitution with concrete principles derived from the 7 rules. The constitution serves as the SpecKit governance layer, while `.cursor/rules/` files serve as the Cursor-specific enforcement layer.

**Rationale**: The constitution (`.specify/memory/constitution.md`) is used by SpecKit agents during planning/review. The Cursor rules are used by the IDE agent during coding. Both express the same principles but for different consumers.

## R5: File Naming Convention for Rules

**Decision**: Use `rule-NN-kebab-name.mdc` format:
- `architecture-overview.mdc`
- `rule-01-explicit-typing.mdc`
- `rule-02-semantic-jsdoc.mdc`
- `rule-03-anti-currying.mdc`
- `rule-04-pure-domain.mdc`
- `rule-05-flat-orchestration.mdc`
- `rule-06-typed-boundaries.mdc`
- `rule-07-module-isolation.mdc`

**Rationale**: kebab-case matches project conventions. Two-digit numbering preserves sort order. `.mdc` extension is required for Cursor frontmatter support.

**Update from spec**: FR-014 specified `.md` files but Cursor requires `.mdc` for frontmatter. The plan uses `.mdc`.
