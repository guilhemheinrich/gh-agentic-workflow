---
name: qa-specify
description: >-
  E2E specification command driven by project analysis. Scans all existing specs
  to learn conventions, identifies E2E gaps, and directly produces complete
  specs (spec.md, plan.md, tasks.md) aligned with project quality and patterns.
  Unlike qa-tester (analysis only), this command produces deliverables.
model: claude-4.6-opus-max-thinking
tags:
  - e2e
  - spec-kit
  - testing
---

# `/qa-specify` — Analysis-Driven E2E Specification

This command combines deep project analysis with the direct production of complete E2E specifications. It doesn't just find gaps — it fills them.

## Usage

```
/qa-specify [optional scope description]
```

**Examples**:

- `/qa-specify` — full analysis, produces specs for all E2E gaps
- `/qa-specify auth flows` — targets authentication flows only
- `/qa-specify specs/047-*` — targets a specific spec

## Difference with `/specify` and qa-tester

| Aspect | `/specify` | qa-tester (agent) | `/qa-specify` |
|--------|-----------|-------------------|---------------|
| Input | Feature description | None (full scan) | Optional scope |
| Prior analysis | No | Yes (gap analysis) | Yes (deep context + gap) |
| Convention learning | No | Partial | **Total** |
| Output | 1 isolated spec | `/specify` prompts | **Direct complete specs** |
| Project knowledge | Limited to prompt | User story scan | **Total immersion** |

---

## Phase 0: Project Immersion (MANDATORY)

**Objective**: Build a complete mental model of the project before producing anything.

### 0.1 Exhaustive Inventory

Scan **all** the specification tree:

```
specs/
specs/archive/
specs/Archive/
```

For each spec folder, record:
- Folder name (e.g., `001-bootstrap-dx`, `047-bug-report`)
- Status: active / archived
- Files present: `spec.md`, `plan.md`, `tasks.md`, `review.md`, `stats.md`
- Approximate `spec.md` size (line count)

### 0.2 Specification Pattern Analysis

Read **every** `spec.md` in the project (not a sample — **all of them**). For each spec, extract:

| Dimension | What to extract |
|-----------|----------------|
| **Structure** | Section headings, sub-section depth, ordering |
| **User Story format** | Style used (As a.../Given-When-Then/narrative/table) |
| **Acceptance criteria** | Average count per story, level of detail, edge cases |
| **Requirements format** | Numbering (FR-XXX, etc.), categorization |
| **Success criteria** | Measurability, granularity |
| **Edge cases** | Thoroughness of edge case documentation |
| **Cross-references** | How specs reference each other |
| **Vocabulary** | Recurring domain terminology |
| **Technical patterns** | Shared UI components, routing patterns, state management |

Store as `$SPEC_PATTERNS`.

### 0.3 Identifying Exemplary Specs

Identify the **3 to 5 best specs** in the project based on:
- Completeness (all sections filled, no placeholders)
- Depth (exhaustive acceptance criteria, edge cases)
- Clarity (unambiguous language, measurable criteria)
- Consistency (regular structure, conventions respected)

Store as `$BENCHMARK_SPECS`. These specs serve as the **quality benchmark** for everything produced.

### 0.4 Plan and Task Analysis

Read `plan.md` and `tasks.md` from the exemplary specs. Record:

| Dimension | What to extract |
|-----------|----------------|
| **Plan structure** | Sections, tech stack format, architecture decision format |
| **Task format** | Checkbox style, ID format, parallelism markers |
| **Task granularity** | Average count per spec, detail per task |
| **Phase organization** | Grouping, checkpoint conventions |

Store as `$TASK_PATTERNS`.

### 0.5 UI Cartography

Build a lightweight map of the UI architecture:
- Component structure (tree)
- Route/page structure
- UI library used (shadcn, Radix, custom, etc.)
- State management patterns
- Custom web components (shadow DOM, etc.)

Store as `$UI_MAP`.

### 0.6 Existing E2E Infrastructure Detection

Identify what already exists:
- Test framework (Playwright, Cypress, etc.)
- Configuration files (playwright.config.ts, etc.)
- Existing fixtures and helpers
- Already written E2E tests (folder, count, patterns)
- npm/make scripts for tests

Store as `$E2E_INFRA`.

### 0.7 Contextual Summary

Produce an internal document `$PROJECT_CONTEXT`:

```
Project: [name]
Total Specs: [count] (active: [N], archived: [N])
Exemplary Specs: [list with justification]
UI Stack: [detection]
E2E Infra: [framework, config, N existing tests]
Spec Convention:
  - User Story Format: [format]
  - Average Acceptance Criteria/story: [N]
  - Requirements Format: [format]
  - Task Format: [format]
  - Average Tasks/spec: [N]
Domain Vocabulary: [key terms]
```

---

## Phase 1: Extraction and Gap Analysis

### 1.1 UI User Story Extraction

For each active `spec.md`, extract all user stories involving UI interaction:
- Screen, form, button, dialog, page, view interaction
- Navigation (page, link, menu)
- Visual feedback (message, notification, loading, error)
- Data display (list, table, dashboard, detail view)
- Input action (entry, selection, upload, drag)

**Exclude** stories that are purely:
- Backend (API-to-API, cron, migrations)
- Infrastructure (deployment, CI/CD, monitoring)
- DX (tooling, CLI, documentation)

For each extracted story, record:

| Field | Description |
|-------|-------------|
| `id` | Unique identifier: `US-[spec-folder]-[N]` |
| `spec_source` | Spec folder name |
| `summary` | Full user story text |
| `acceptance_criteria` | Acceptance criteria **verbatim** (no summarizing) |
| `ui_elements` | UI elements involved |
| `related_specs` | Other specs sharing UI components/flows |
| `complexity` | Estimated E2E complexity: Simple / Medium / Complex |

### 1.2 Existing E2E Coverage Detection

Search for existing coverage:
1. E2E test files (`*.spec.ts`, `*.e2e.ts`, e2e/ folders)
2. Specs targeting E2E tests (folders or content mentioning "e2e", "end-to-end", "playwright")
3. Tasks in `tasks.md` related to E2E tests

### 1.3 Gap Calculation

```
$UNCOVERED = $UI_STORIES \ $COVERED
```

Group by source spec. Enrich each uncovered story with:
- **Similar covered stories** (potential templates)
- **Shared UI components** with covered stories
- **Dependency chains** (prerequisites for testing)

### 1.4 Prioritization

Rank gaps by priority:

| Priority | Criteria |
|----------|----------|
| **P0 — Critical** | Main user flows (auth, primary CRUD, critical business actions) |
| **P1 — High** | Important secondary flows (settings, preferences, UI error handling) |
| **P2 — Medium** | Complementary flows (cosmetic, non-critical interactions) |

---

## Phase 2: E2E Spec Grouping

### 2.1 Grouping Strategy

Do not create one spec per user story. Group intelligently:

| Strategy | When to apply |
|----------|---------------|
| **By user flow** | Stories that form a complete journey (e.g., signup → verification → first login) |
| **By shared component** | Stories that test the same component in different contexts |
| **By source spec** | Stories from the same spec that are coherent together |
| **By complexity** | Isolate complex stories that deserve a dedicated spec |

### 2.2 Spec Production Plan

For each group, define:

```
E2E Spec #[N]: [descriptive title]
  Source(s): [origin spec folder(s)]
  Stories covered: [US-XXX-N, US-XXX-M, ...]
  Priority: P0 / P1 / P2
  Complexity: Simple / Medium / Complex
  Dependencies: [prerequisite E2E specs, or none]
```

Present the plan to the user for validation before producing specs.

---

## Phase 3: Spec Production (for each validated group)

### 3.1 Numbering

**MANDATORY**: Apply the indexing rules defined in `.cursor/rules/05-workflows-and-processes/5-spec-indexing.mdc` (section 4 — Computing the Next Available Index).

In summary:
1. Scan `specs/`, `fixes/`, and `specs/archive/` (if existing)
2. Find `MAX(NNN)` among all indexed folders
3. Next index = `MAX + 1`, 3-digit zero-padded format
4. If an index conflict is detected → run `/index` before continuing

Folder naming convention:
```
specs/[NNN]-e2e-[short-description]/
```

### 3.2 Create the Git Branch

```bash
git checkout -b feature/[NNN]-e2e-[description]
```

### 3.3 Save the Prompt

Create `specs/[NNN]-e2e-[description]/prompt.md` with:
- The `/qa-specify` command invoked
- The analysis context (summary of the identified gap)
- The targeted user stories

### 3.4 Produce `spec.md`

**CRITICAL**: The produced spec.md MUST:
1. **Follow exactly** the structure observed in `$BENCHMARK_SPECS`
2. **Use the user story format** of the project (`$SPEC_PATTERNS`)
3. **Match or exceed** the project's average depth
4. **Use the domain vocabulary** identified in Phase 0
5. **Reference source specs** and shared components
6. **Include edge cases** at the same level of detail as the benchmark specs

Minimum structure (adapted to project conventions):

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
[... as many as needed — at least as many as the source spec]

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
| [component] | `[proposed-testid]` | [used in which test] |

## Source Code Policy (CRITICAL)

The source application MUST NOT be modified, except to add `data-testid`
attributes to existing UI components listed above.
No modifications to logic, styles, structure, or behavior.

## Success Criteria

- **SC-001**: [Measurable, technology-agnostic criterion]
- **SC-002**: [Measurable, technology-agnostic criterion]
```

### 3.5 Produce `plan.md`

Follow the structure from `$TASK_PATTERNS`. Include:
- Technical approach (framework, configuration, fixtures)
- Test architecture (folders, shared helpers)
- Execution strategy (parallelism, CI, reporting)
- Reference to existing tests (`$E2E_INFRA`) as a base

### 3.6 Produce `tasks.md`

Strictly follow the format from `$TASK_PATTERNS`:

```text
- [ ] TXXX [P?] [USN?] Description with file path
```

Phase organization:

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

### 3.7 Initialize `stats.md`

Follow the project's `stats.md` format (observed in `$BENCHMARK_SPECS`).

---

## Phase 4: Summary Report

After producing all specs, present:

```markdown
## /qa-specify Report

### Project Analysis

| Metric | Value |
|--------|-------|
| Specs analyzed | X |
| Exemplary specs identified | N |
| UI user stories extracted | X |
| Already covered by E2E | X |
| **Gaps identified** | **X** |

### E2E Specs Produced

| # | Folder | Stories covered | Priority | Tasks |
|---|--------|----------------|----------|-------|
| 1 | `NNN-e2e-description` | US-XXX-1, US-XXX-2 | P0 | X tasks |

### Quality & Compliance

| Criterion | Status |
|-----------|--------|
| Structure aligned with $BENCHMARK_SPECS | OK / Deviation: [reason] |
| User story format compliant | OK |
| Acceptance criteria depth | OK / [N] vs project average [M] |
| Task format compliant | OK |
| Cross-references included | OK |
| Source code policy explicit | OK |

### Next Steps

1. Review the produced specs
2. For each spec, delegate to the implementer:
   ```
   Use the implementer subagent to: /implement [NNN]
   ```
3. After implementation, run the review:
   ```
   /review-implemented [NNN]
   ```
```

---

## Critical Rules

- **NEVER produce a spec without having read ALL existing specs** in Phase 0
- **NEVER summarize acceptance criteria** — copy them verbatim from source specs
- **ALWAYS identify benchmark specs** and align with their quality
- **ALWAYS follow the format conventions** observed in the project
- **ALWAYS include cross-references** to source specs and related specs
- **ALWAYS include the source code policy** in each spec.md
- **The source application MUST NOT be modified** except for adding `data-testid`
- **Create a Git branch** before starting to write
- **Run ALL commands via Docker** if the project uses Docker — NEVER on the host
- **Follow `.cursor/rules/`** and `AGENTS.md` for project conventions
- **Use Context7 MCP** for Playwright and Spec-Kit documentation

## Model Requirement

| Priority | Model | ID |
|----------|-------|----|
| **Preferred** | Claude 4.6 Opus Max Thinking | `claude-opus-4-6-max-thinking` |
| **Fallback (without Max Mode)** | Claude 4.6 Opus Thinking | `claude-opus-4-6-thinking` |

Extended reasoning capability is essential for the exhaustive analysis of 50+ specs, reliable pattern identification, and production of benchmark-quality specs.
