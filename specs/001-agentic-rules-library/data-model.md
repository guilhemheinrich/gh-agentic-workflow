# Data Model: Agentic Rules Library

**Date**: 2026-04-05
**Branch**: `001-agentic-rules-library`

## Entities

This feature produces static configuration files, not runtime data. The "data model" describes the structure of the rule files themselves.

### CursorRule

A Cursor rule file (`.mdc`) with the following structure:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| description | string | yes | One-line summary for agent-decided activation |
| alwaysApply | boolean | yes | Whether rule applies to every interaction |
| globs | string[] | no | File patterns for auto-attach activation |
| ruleId | string (in body) | yes | Unique identifier (e.g., "Rule 1", "Rule 2") |
| context | string (in body) | yes | Why this rule exists (optimization target) |
| directive | string (in body) | yes | What to do / not do |
| positiveExample | code block | yes | Compliant code example |
| negativeExample | code block | yes | Non-compliant code example |
| skillReferences | link[] | no | Links to `skills/fp-ts-*/SKILL.md` files |

### ArchitectureOverview

The index rule file that ties all rules together:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| description | string | yes | "Architecture overview for TypeScript/NestJS backend" |
| alwaysApply | boolean | yes | Always `true` |
| directoryStructure | code block | yes | Canonical folder layout |
| ruleIndex | table | yes | Table linking to all 7 rule files with summaries |
| stackDefinition | section | yes | TypeScript + NestJS + Effect/fp-ts + Zod |

### Constitution

The SpecKit governance document (`.specify/memory/constitution.md`):

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| principles | section[] | yes | Core principles derived from the 7 rules |
| governance | section | yes | How the constitution is enforced |
| version | string | yes | Semantic version |

## Relationships

```
ArchitectureOverview (1) --references--> (7) CursorRule
CursorRule (0..N) --links-to--> (0..N) Skill (fp-ts-*)
Constitution (1) --mirrors--> (1) ArchitectureOverview (same principles, different format)
```

## File Structure

```
.cursor/rules/
├── architecture-overview.mdc       # Always-apply index (links to all rules)
├── rule-01-explicit-typing.mdc     # Agent-decided
├── rule-02-semantic-jsdoc.mdc      # Agent-decided
├── rule-03-anti-currying.mdc       # Agent-decided
├── rule-04-pure-domain.mdc         # Agent-decided
├── rule-05-flat-orchestration.mdc  # Agent-decided
├── rule-06-typed-boundaries.mdc    # Agent-decided
└── rule-07-module-isolation.mdc    # Agent-decided

.specify/memory/
└── constitution.md                 # SpecKit governance (replaces template)

skills/                             # Pre-existing, referenced by rules
├── fp-ts-pragmatic/SKILL.md
├── fp-ts-errors/SKILL.md
├── fp-ts-validation/SKILL.md
├── fp-ts-backend/SKILL.md
└── fp-ts-async-practical/SKILL.md
```
