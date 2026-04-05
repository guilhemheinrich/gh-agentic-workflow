# Implementation Plan: Agentic Rules Library

**Branch**: `001-agentic-rules-library` | **Date**: 2026-04-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-agentic-rules-library/spec.md`

## Summary

Create a library of 8 Cursor rule files (`.mdc`) encoding 7 architecture rules for TypeScript/NestJS/fp-ts backend projects following the Vertical Slices + Functional Core / Imperative Shell pattern. The rules are optimized for LLM indexing (AST, RAG, Tree-sitter) and cross-reference existing fp-ts skills for detailed implementation guidance. A SpecKit constitution file mirrors the same principles for planning/review workflows.

## Technical Context

**Language/Version**: Markdown (`.mdc` Cursor rule files), TypeScript code examples within rules
**Primary Dependencies**: Cursor IDE (rule consumer), existing fp-ts skills (linked references)
**Storage**: N/A (static files)
**Testing**: Manual verification via Cursor agent queries + structural validation (file existence, link resolution, line count)
**Target Platform**: Cursor IDE on any OS
**Project Type**: Configuration library (Cursor rules + SpecKit constitution)
**Performance Goals**: Each rule file < 500 lines (single RAG embedding chunk)
**Constraints**: 8 files total in `.cursor/rules/`, 1 constitution file in `.specify/memory/`
**Scale/Scope**: 7 rules, ~300-400 lines each, ~50 lines for overview

## Constitution Check

*GATE: The current constitution is a blank template. This feature replaces it with concrete principles.*

| Gate | Status | Notes |
|------|--------|-------|
| Constitution exists | PASS (template) | Will be replaced with real content |
| No violations | PASS | Feature creates the constitution itself |

## Project Structure

### Documentation (this feature)

```text
specs/001-agentic-rules-library/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output (Cursor rules format research)
├── data-model.md        # Phase 1 output (rule file structure)
├── quickstart.md        # Phase 1 output (installation/usage guide)
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
.cursor/rules/
├── architecture-overview.mdc       # Always-apply index rule
├── rule-01-explicit-typing.mdc     # Agent-decided: explicit types in domain
├── rule-02-semantic-jsdoc.mdc      # Agent-decided: JSDoc for RAG optimization
├── rule-03-anti-currying.mdc       # Agent-decided: no deep currying
├── rule-04-pure-domain.mdc         # Agent-decided: functional core purity
├── rule-05-flat-orchestration.mdc  # Agent-decided: flat pipe() use cases
├── rule-06-typed-boundaries.mdc    # Agent-decided: Zod at I/O boundaries
└── rule-07-module-isolation.mdc    # Agent-decided: no cross-module imports

.specify/memory/
└── constitution.md                 # SpecKit governance document (replaces template)
```

**Structure Decision**: No `src/` directory needed. This feature produces only configuration/documentation files consumed by Cursor and SpecKit. All deliverables are in `.cursor/rules/` and `.specify/memory/`.

## Architecture

### Rule File Internal Structure

Each rule `.mdc` file follows this consistent structure:

```markdown
---
description: "Rule N: [Name] — [one-line summary for Cursor agent discovery]"
alwaysApply: false
---

# Rule N: [Name]

## Context
[Why this rule exists — optimization target (LSP, RAG, AST, etc.)]

## Directive
[Actionable instruction — what to do and what NOT to do]

## Examples

### Compliant (DO)
[TypeScript code example showing correct pattern]

### Non-Compliant (DON'T)
[TypeScript code example showing violation + explanation]

## Skill References
[Links to relevant fp-ts skills for detailed patterns — only for Rules 3, 4, 5, 6]

## Enforcement
[How the agent should detect and correct violations of this rule]
```

### Overview File Structure

The `architecture-overview.mdc` is `alwaysApply: true` and contains:
1. The canonical directory structure (Screaming Architecture)
2. A rule index table with links to each rule file
3. The tech stack definition (TypeScript + NestJS + Effect/fp-ts + Zod)
4. Quick decision tree: "Which rule applies to my current file?"

### Constitution Structure

The constitution mirrors the 7 rules as governance principles for SpecKit:
1. Principle I: Explicit Type Contracts
2. Principle II: Semantic Documentation
3. Principle III: Readable Functional Style
4. Principle IV: Pure Functional Core
5. Principle V: Flat Orchestration
6. Principle VI: Typed I/O Boundaries
7. Principle VII: Module Isolation

### Skill Reference Mapping

| Rule | Referenced Skills | Why |
|------|------------------|-----|
| Rule 3 (Anti-Currying) | [fp-ts-pragmatic](../../skills/fp-ts-pragmatic/SKILL.md) | Named params, pipe patterns, anti-point-free guidance |
| Rule 4 (Pure Domain) | [fp-ts-errors](../../skills/fp-ts-errors/SKILL.md), [fp-ts-backend](../../skills/fp-ts-backend/SKILL.md) | Either/TaskEither typed errors, ReaderTaskEither for DI |
| Rule 5 (Flat Orchestration) | [fp-ts-pragmatic](../../skills/fp-ts-pragmatic/SKILL.md), [fp-ts-async-practical](../../skills/fp-ts-async-practical/SKILL.md) | pipe/flow composition, async pipeline patterns |
| Rule 6 (Typed Boundaries) | [fp-ts-validation](../../skills/fp-ts-validation/SKILL.md) | Validation with error accumulation, Zod integration |

### RAG Optimization Strategy

Each rule file is designed for optimal embedding:
- **Self-contained**: Each file has complete context (no cross-file dependencies to understand it)
- **Semantic anchors**: Rule name, context, directive are in natural language headers (high embedding quality)
- **Code examples inline**: Positive/negative examples in the same file (single chunk retrieval)
- **< 500 lines**: Fits within a single embedding chunk for `text-embedding-3-small`
- **Consistent structure**: Identical heading hierarchy across all rules (predictable chunk boundaries)

## Complexity Tracking

No constitution violations to justify — this feature creates the constitution.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| File format | `.mdc` (not `.md`) | Required for Cursor frontmatter (activation control) |
| Overview activation | `alwaysApply: true` | Always available as architecture context |
| Individual rules activation | Agent-decided (`alwaysApply: false`) | Saves context window; agent loads on demand |
| Skill references | Relative Markdown links | Portable across machines; Cursor resolves them |
| Constitution format | SpecKit constitution (governance prose) | Different consumer than Cursor rules; same principles |
