# gh-agentic-workflow — Agentic Architecture Constitution

This constitution governs SpecKit planning and reviews for backend TypeScript work in this repository. Detailed Cursor enforcement lives in `.cursor/rules/` (see `architecture-overview.mdc` and `rule-0X-*.mdc`).

## Core Principles

### I. Explicit Type Contracts (Rule 1)

All pure domain logic exposes explicit input and output types. `any` and opaque inference-only APIs are forbidden in `/domain`. Types are the contract between human reviewers, the TypeScript compiler, and retrieval-augmented coding agents.

### II. Semantic Documentation (Rule 2)

Every domain file carries a file-level responsibility comment. Every exported pure function has a JSDoc `@description` in natural language so embeddings and search retrieve intent, not only syntax.

### III. Readable Functional Style (Rule 3)

Prefer named parameters objects and named intermediate values over deep currying and excessive point-free style. Code is written for humans and LLM chunk boundaries first; clever FP second.

### IV. Pure Functional Core (Rule 4)

The `/domain` layer contains only pure functions: no NestJS, no I/O, no `throw`. Errors are values (e.g. `Effect`, `Either`, `TaskEither`). When a module has fewer than five pure functions, merge model and logic into a single `[module].domain.ts` file to keep one retrieval chunk.

### V. Flat Orchestration (Rule 5)

Application use cases are NestJS injectable services that orchestrate with a straight, readable pipeline: validate input → call domain → persist via ports. No nested business branching inside the service shell; complexity stays in typed domain functions.

### VI. Typed I/O Boundaries (Rule 6)

All data entering or leaving the process through HTTP or persistence adapters is structurally validated (Zod or `@effect/schema`). Infrastructure filenames declare technology (`sql_*.repository.ts`, `http_*.gateway.ts`).

### VII. Strict Module Isolation (Rule 7)

Vertical slices do not import another module’s `domain`, `application`, or `internal` infrastructure. Shared concepts live under `src/shared/` or cross-module contracts; integration uses public facades (services, events), not deep imports.

## Additional Constraints

- **Stack**: TypeScript, NestJS (imperative shell), Effect or fp-ts (functional core), Zod or Effect Schema at boundaries unless a feature spec explicitly varies this.
- **Layout**: `src/modules/<feature>/` with `domain/`, `application/use-cases/`, `infrastructure/persistence/`, `infrastructure/http/`, plus `src/shared/` for cross-cutting types and clients.
- **AI tooling**: Cursor rules and optional skills under `skills/` are normative for agent-generated code; they do not replace code review or CI.

## Development Workflow

- Feature work follows SpecKit phases (specify → plan → tasks → implement → verify) when using the fleet workflow.
- Constitution checks in `plan.md` must pass before implementation; amendments require a PR that updates this file and linked `.cursor/rules/` when principles change.

## Governance

- This constitution supersedes ad-hoc style preferences for backend TypeScript in this repo.
- **Amendments**: Propose a PR with rationale, update `.cursor/rules/` if user-facing rules change, and bump the version below.
- **Compliance**: Reviewers verify new modules match vertical-slice layout and boundary rules; the verify extension may flag drift against `spec.md` / `tasks.md` when used.

**Version**: 1.0.0 | **Ratified**: 2026-04-05 | **Last Amended**: 2026-04-05
