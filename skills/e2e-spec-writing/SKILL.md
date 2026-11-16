---
name: e2e-spec-writing
description: >-
  Write complete E2E test specifications (spec.md, plan.md, tasks.md) following
  project conventions. Use when producing E2E specs, writing end-to-end test
  scenarios, specifying Playwright/Cypress tests, or when a specify/speckit
  command needs to output E2E deliverables.
tags:
  - documentation
  - e2e
  - spec-kit
  - testing
---

Requires spec-kit (spec-driven development).

# E2E Spec Writing

Produce `spec.md`, `plan.md` and `tasks.md` for E2E test scenarios, at the
depth of the project's benchmark specs.

**Before writing, have**: the list of user stories to cover; the project spec
conventions (`$SPEC_PATTERNS`, `$BENCHMARK_SPECS`, `$TASK_PATTERNS`); the E2E
infrastructure (`$E2E_INFRA`: framework, config, existing tests); the UI map
(`$UI_MAP`). If missing, read existing specs and the codebase first.

## 1. Grouping

Do not make one spec per story. Group by user flow, shared component, source
spec, or isolate complex stories. Priorities: P0 critical flows (auth, primary
CRUD, key business actions), P1 important secondary flows, P2 complementary.

## 2. Folder naming

`specs/[NNN]-e2e-[short-description]/`. Compute `[NNN]` from the project's
indexing rules: scan `specs/`, `fixes/`, `specs/archive/`, take `MAX(NNN) + 1`,
3-digit zero-padded.

## 3. Templates

Adapt sections and formats to the benchmark specs.

- `templates/spec.md` - quality bar: same structure, story format, vocabulary
  and edge-case depth as the benchmarks; cross-reference source specs.
- `templates/plan.md`
- `templates/tasks.md` - phase order is fixed: setup, data-testid (the only
  permitted app modification), one phase per user story, final validation;
  checkpoints between phases.

## 4. Critical rules

- Follow the format conventions of the benchmark specs.
- Never summarize acceptance criteria: copy verbatim from source specs, then
  extend for the E2E context.
- Always cross-reference source specs and related specs.
- Always include the Source Code Policy section: the app must not be modified
  except for adding `data-testid`.
- The Data-TestID table is mandatory: it is the contract between spec and
  implementation.
- Follow `.cursor/rules/` and `AGENTS.md`.
