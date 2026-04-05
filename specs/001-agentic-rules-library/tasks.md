# Tasks: Agentic Rules Library

**Input**: Design documents from `/specs/001-agentic-rules-library/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Not requested in spec — verification tasks are manual (line count, link resolution).

**Organization**: Tasks grouped by user story; `[P]` marks parallel-safe work (different files, no ordering dependency within the group).

**Fleet**: Organize `[P]` tasks into explicit parallel groups with `<!-- parallel-group: N -->` comments (max 3 concurrent subagents per group).

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Ensure target directories exist and avoid conflicts with existing Cursor context files.

- [x] T001 [US1] Verify or create `.cursor/rules/` at repo root `D:/code/gh-agentic-workflow/.cursor/rules/` and list existing `.mdc` files (note `specify-rules.mdc` from SpecKit agent context).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: SpecKit governance artifact required by FR-015 before treating the feature as complete.

- [x] T002 [US1] Replace `.specify/memory/constitution.md` with concrete principles (I–VII aligned to Rules 1–7), governance section, and version metadata per plan.md and spec FR-015.

**Checkpoint**: Constitution exists — parallel rule file work can proceed.

---

## Phase 3: User Story 1 — Bootstrap & Vertical Slice Structure (Priority: P1)

**Goal**: Deliver Cursor rules that encode canonical `src/modules/[module]/…` layout, naming, JSDoc boilerplate, and merge threshold for small domains.

**Independent Test**: Open project in Cursor; ask the agent to scaffold a module — responses cite `architecture-overview.mdc` and correct folder names.

### Implementation

<!-- parallel-group: 1 (max 3 concurrent) -->
- [x] T003 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-01-explicit-typing.mdc` — Rule 1: explicit input/output types in `/domain`, no `any`, positive/negative TS examples, `alwaysApply: false`, description for agent-decided loading per research.md.

- [x] T004 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-02-semantic-jsdoc.mdc` — Rule 2: file header + `@description` on pure functions, RAG-oriented wording, examples.

- [x] T005 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-03-anti-currying.mdc` — Rule 3: forbid deep currying/point-free excess; use named params object; link to `skills/fp-ts-pragmatic/SKILL.md` per FR-004/US4.

<!-- parallel-group: 2 (max 3 concurrent) -->
- [x] T006 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-04-pure-domain.mdc` — Rule 4: no NestJS/DB/`throw` in domain; Effect/fp-ts typed errors; merge `<5` functions into `[module].domain.ts`; links to `skills/fp-ts-errors/SKILL.md` and `skills/fp-ts-backend/SKILL.md`.

- [x] T007 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-05-flat-orchestration.mdc` — Rule 5: use cases as `@Injectable()` flat `pipe()` Input→Validation→Logic→Persistence; links to `skills/fp-ts-pragmatic/SKILL.md` and `skills/fp-ts-async-practical/SKILL.md`.

- [x] T008 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-06-typed-boundaries.mdc` — Rule 6: Zod or `@effect/schema` at controllers/repos; `sql_*.repository.ts` / `http_*.gateway.ts` naming; link to `skills/fp-ts-validation/SKILL.md`.

<!-- parallel-group: 3 (max 3 concurrent) -->
- [x] T009 [P] [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/rule-07-module-isolation.mdc` — Rule 7: no cross-module imports into `domain/`/`application/`/`infrastructure/` of other modules; `shared/domain` allowed; enforcement cues for agents.

<!-- sequential -->
- [x] T010 [US1] Create `D:/code/gh-agentic-workflow/.cursor/rules/architecture-overview.mdc` — `alwaysApply: true`; YAML description; canonical directory tree from spec FR-001; tech stack; markdown table linking to `rule-01`…`rule-07` files; decision tree “which rule applies?”.

**Checkpoint**: All eight `.mdc` files exist — US1 scaffolding guidance is deliverable.

---

## Phase 4: User Story 2 — Agent Enforcement Guidance (Priority: P2)

**Goal**: Each rule documents how the agent should detect violations and suggest fixes (spec User Story 2).

**Independent Test**: Paste intentionally bad code — agent cites rule ID and remediation.

- [x] T011 [US2] Review all eight `.mdc` files under `D:/code/gh-agentic-workflow/.cursor/rules/` and ensure each has an **Enforcement** subsection (or equivalent) with detectable signals (imports, patterns) and fix strategy per spec FR-002–FR-003.

---

## Phase 5: User Story 3 — RAG / Chunk Optimization (Priority: P3)

**Goal**: Self-contained files, semantic headings, SC-006 line limit.

**Independent Test**: Each rule file under 500 lines; headings consistent across rules.

- [x] T012 [US3] For each file in `D:/code/gh-agentic-workflow/.cursor/rules/*.mdc`, confirm line count ≤ 500 (SC-006); trim or split content if needed without losing FR-003 examples.

---

## Phase 6: User Story 4 — Skill References (Priority: P2)

**Goal**: Valid relative links to repo `skills/` per FR-004 and User Story 4.

**Independent Test**: Paths `skills/fp-ts-pragmatic/SKILL.md`, `fp-ts-errors`, `fp-ts-validation`, `fp-ts-backend`, `fp-ts-async-practical` resolve from repo root.

- [x] T013 [US4] Validate Markdown links from Rules 3–6 in `D:/code/gh-agentic-workflow/.cursor/rules/rule-0[3-6]-*.mdc` point to existing files under `D:/code/gh-agentic-workflow/skills/`; fix paths if broken.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T014 [P] Update `D:/code/gh-agentic-workflow/specs/001-agentic-rules-library/spec.md` FR-014 to explicitly allow `.mdc` (Cursor frontmatter) as the delivered format, aligning spec with plan.md/research.md (resolves architecture-rules checklist CHK009/CHK025).

- [x] T015 Reconcile `D:/code/gh-agentic-workflow/.cursor/rules/specify-rules.mdc` (SpecKit context) with new architecture rules: avoid duplicate/conflicting always-apply content; reference or merge overview per team preference.

- [x] T016 Walk through `D:/code/gh-agentic-workflow/specs/001-agentic-rules-library/quickstart.md` installation steps against the repo after files exist; update quickstart if paths or filenames differ.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No prerequisites.
- **Phase 2 (Constitution)**: Can run after T001; blocks feature acceptance for FR-015 but not creation of `.mdc` files (parallelizable with Phase 3 if two agents — constitution vs rules).
- **Phase 3 (Rules + overview)**: T010 should run after T003–T009 so overview can reference finalized rule filenames and summaries.
- **Phases 4–7**: Depend on Phase 3 artifacts (content exists to review).

### User Story Dependencies

- **US1**: T003–T010 — core deliverable MVP.
- **US2**: T011 — builds on US1 content.
- **US3**: T012 — builds on US1 files.
- **US4**: T013 — builds on Rules 3–6 from US1.

### Parallel Opportunities

- **T003–T005**: Three separate files — parallel group 1.
- **T006–T008**: Three separate files — parallel group 2.
- **T009**: Single file — parallel group 3 (or run after group 2).
- **T014–T015**: Different files — can run in parallel after main rules exist.

---

## Implementation Strategy

### MVP (User Story 1 only)

1. T001 → T002 (optional: run T002 parallel with rule files if staffed)
2. T003–T009 (parallel groups), then T010
3. Stop — validate quickstart scaffolding scenario

### Full Feature

1. Complete through T016
2. Run Phase 9 verify / manual review

---

## Task Summary

| Metric | Value |
|--------|-------|
| Total tasks | 16 |
| Parallel groups | 3 (rules 1–3, 4–6, 7) |
| MVP tasks | T001–T010 (US1) |
| Per-story task counts | US1: T001,T003–T010; US2: T011; US3: T012; US4: T013; Polish: T014–T016 |

---

## Notes

- All rule filenames use kebab-case and `.mdc` per research.md and plan.md.
- Skills live at `D:/code/gh-agentic-workflow/skills/<name>/SKILL.md` — use repo-relative links in rules as `skills/...` for portability.
