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

# E2E Spec Writing

How to produce complete, benchmark-quality E2E test specifications. This skill covers the structure and content of `spec.md`, `plan.md`, and `tasks.md` for E2E test scenarios.

**Prerequisite**: Before writing, you must already have:
- The list of user stories/scenarios to cover
- Knowledge of project spec conventions (`$SPEC_PATTERNS`, `$BENCHMARK_SPECS`)
- The E2E infrastructure context (`$E2E_INFRA`: framework, config, existing tests)
- The UI map (`$UI_MAP`: components, routes, state management)

If you don't have this context, gather it first by reading existing specs and the project codebase.

---

## 1. Grouping Scenarios into Specs

Don't create one spec per user story. Group intelligently:

| Strategy | When to apply |
|----------|---------------|
| **By user flow** | Stories forming a complete journey (e.g., signup → verification → first login) |
| **By shared component** | Stories testing the same component in different contexts |
| **By source spec** | Stories from the same spec that are coherent together |
| **By complexity** | Isolate complex stories that deserve a dedicated spec |

Prioritize groups:

| Priority | Criteria |
|----------|----------|
| **P0 — Critical** | Main user flows (auth, primary CRUD, critical business actions) |
| **P1 — High** | Important secondary flows (settings, preferences, UI error handling) |
| **P2 — Medium** | Complementary flows (cosmetic, non-critical interactions) |

---

## 2. Folder Naming

```
specs/[NNN]-e2e-[short-description]/
```

Apply the project's spec indexing rules to compute `[NNN]` (scan `specs/`, `fixes/`, `specs/archive/`; find `MAX(NNN)`; next = `MAX + 1`, 3-digit zero-padded).

---

## 3. Writing `spec.md`

### Quality Rules

The produced `spec.md` **MUST**:
1. Follow exactly the structure observed in the project's benchmark specs
2. Use the project's user story format
3. Match or exceed the project's average depth of acceptance criteria
4. Use the project's domain vocabulary
5. Reference source specs and shared components
6. Include edge cases at the same level of detail as benchmark specs

### Template

Adapt this to the project's conventions — sections, headings, and formats should mirror the benchmark specs:

```markdown
# E2E Test Specification: [Title]

**Feature Branch**: `[NNN]-e2e-[description]`
**Created**: [YYYY-MM-DD]
**Status**: Draft
**Source Specs**: [list of source specs]
**E2E Framework**: [Playwright/Cypress — from $E2E_INFRA]

## Context

[Why these E2E tests are needed. Reference to source specs.
Description of user flows covered.]

## User Scenarios & Testing

### User Story 1 — [Title] (Priority: [P0/P1/P2])

[Full user story text, adapted to the E2E context]

**Source**: specs/[XXX-feature]/spec.md
**Why this priority**: [Justification]
**Independent Test**: [How to test this story alone]

**Acceptance Scenarios**:

1. **Given** [context], **When** [action], **Then** [result]
2. **Given** [context], **When** [action], **Then** [result]
[... at least as many as the source spec]

**Edge Cases**:
- [Boundary condition 1] → [expected behavior]
- [Boundary condition 2] → [expected behavior]

### User Story 2 — [Title] (Priority: [P0/P1/P2])
[... same structure ...]

## Requirements

### Functional Requirements

- **FR-001**: The E2E test MUST [testable requirement]
- **FR-002**: The E2E test MUST [testable requirement]
[... follow the project's numbering format]

### Technical Requirements

- **TR-001**: Tests MUST use `data-testid` for element selection
- **TR-002**: Tests MUST use `test.step()` to decompose scenarios
- **TR-003**: Tests MUST be independent (no shared state between tests)

### Data-TestID Requirements

| Component | `data-testid` attribute | Reason |
|-----------|------------------------|--------|
| [component] | [proposed-testid] | [used in which test] |

## Source Code Policy (CRITICAL)

The source application MUST NOT be modified, except to add `data-testid`
attributes to existing UI components listed above.
No modifications to logic, styles, structure, or behavior.

## Success Criteria

- **SC-001**: [Measurable, technology-agnostic criterion]
- **SC-002**: [Measurable, technology-agnostic criterion]
```

### Key Principles

- **Never summarize acceptance criteria** — copy them verbatim from source specs, then expand for the E2E context
- **Always include the Source Code Policy section** — it prevents scope creep
- **Cross-reference source specs** in every user story
- **Data-TestID table is mandatory** — it's the contract between spec and implementation

---

## 4. Writing `plan.md`

Follow the project's plan conventions (`$TASK_PATTERNS`). Include:

- **Technical approach**: framework, configuration, fixtures needed
- **Test architecture**: folder structure, shared helpers, page objects
- **Execution strategy**: parallelism, CI integration, reporting
- **Existing infrastructure**: reference existing tests from `$E2E_INFRA` as a base

---

## 5. Writing `tasks.md`

### Format

Follow the project's task format strictly. Standard format:

```
- [ ] TXXX [P?] [USN?] Description with file path
```

Where `[P]` = parallelizable, `[USN]` = linked user story.

### Phase Organization

```markdown
# Tasks: E2E [description]

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Configure Playwright fixtures for [context]
- [ ] T002 [P] Create shared helpers in tests/e2e/helpers/

## Phase 2: Data-TestID (Only allowed app modification)

- [ ] T003 [P] Add data-testid to [component] in [path]
- [ ] T004 [P] Add data-testid to [component] in [path]

**Checkpoint**: All data-testid in place, app otherwise unchanged

## Phase 3: E2E Tests — [User Story 1]

- [ ] T010 [US1] Create test file tests/e2e/[name].spec.ts
- [ ] T011 [US1] Implement scenario [title]
- [ ] T012 [US1] Implement edge case [title]

**Checkpoint**: User Story 1 tested end-to-end

## Phase N: Final Validation

- [ ] TXXX Run the complete E2E suite
- [ ] TXXX Verify no regressions in existing tests
- [ ] TXXX Update test documentation

## Summary

- Total tasks: [count]
- By priority: P0=[count], P1=[count], P2=[count]
```

### Phase Guidelines

- **Phase 1** is always infrastructure/setup (fixtures, helpers, config)
- **Phase 2** is always data-testid additions — the only permitted app modification
- **Phases 3+** are one per user story or logical group
- **Final phase** is always validation and regression check
- Insert **Checkpoints** between phases for incremental validation

---

## 6. Critical Rules

- **ALWAYS follow format conventions** observed in the project's benchmark specs
- **ALWAYS include cross-references** to source specs and related specs
- **ALWAYS include the Source Code Policy** in each `spec.md`
- **NEVER summarize acceptance criteria** — copy verbatim, then extend
- **The source application MUST NOT be modified** except for adding `data-testid`
- **Follow `.cursor/rules/`** and `AGENTS.md` for project conventions
