# Tasks: Scraper Architecture — Separation of Concerns

**Input**: Design documents from `/specs/010-refactor-scraper-separation/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not requested — no test tasks included.

**Organization**: Tasks grouped by user story for independent implementation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: Create directory structure for the new skill and prepare output conventions.

- [x] T001 Create skill directory structure at .agents/skills/web-analysis/ (SKILL.md, Dockerfile, resources/)
- [x] T002 [P] Create output directory convention documentation in SCRAP/ (tables/, screenshots/, snapshots/, pages/, crawl-log.json)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Define the scraping brief contract that both command and agent depend on.

**⚠️ CRITICAL**: The command and agent rewrites both depend on the brief contract being defined first.

- [x] T003 Define the Scraping Brief YAML schema inline documentation within agents/scraper.md (based on contracts/scraping-brief.md)
- [x] T004 [P] Define the Agent Output contract (return summary format, directory structure) within agents/scraper.md (based on contracts/agent-output.md)

**Checkpoint**: Contract defined — command and agent can now be written independently.

---

## Phase 3: User Story 1 — Goal-Directed Scraping Command (Priority: P1) 🎯 MVP

**Goal**: The command detects scraping intent, builds a scoped brief, delegates to the agent, and verifies deliverables.

**Independent Test**: Invoke `/scrape-site URL="https://example.com" INTENT="data-extraction"` and verify the agent receives a brief with `tables_as_markdown: true`, `max_pages: 15`, and scope filters targeting pricing/data pages.

### Implementation for User Story 1

- [x] T005 [US1] Rewrite commands/scrape-site.md — add intent detection section with keyword mapping table (data-extraction, user-flow, site-structure, general)
- [x] T006 [US1] Add natural-language intent inference logic in commands/scrape-site.md — pattern matching from user description when no explicit INTENT parameter
- [x] T007 [US1] Add Scraping Brief generation section in commands/scrape-site.md — structured YAML brief construction from intent + URL + auth parameters
- [x] T008 [US1] Add intent-based defaults table in commands/scrape-site.md — max_pages, deliverable flags per intent category
- [x] T009 [US1] Add authentication parameter handling in commands/scrape-site.md — AUTH_EMAIL, AUTH_PASSWORD, AUTH_TYPE parameters → brief auth section
- [x] T010 [US1] Add deliverable verification section in commands/scrape-site.md — check agent output against expected artifacts per intent
- [x] T011 [US1] Add retry logic in commands/scrape-site.md — re-invoke agent for missing deliverables (max 1 retry)
- [x] T012 [US1] Add user-facing summary output in commands/scrape-site.md — report paths, counts, errors after verification

**Checkpoint**: Command fully functional — can detect intent, build brief, delegate, and verify.

---

## Phase 4: User Story 2 — Agent as Pure Navigator (Priority: P1)

**Goal**: The agent navigates, extracts raw DOM data (especially tables/structured data), captures screenshots, and reports without any interpretation.

**Independent Test**: Run the agent on a site with HTML tables — verify output contains markdown table files in `SCRAP/{DOMAIN}/tables/` with source URL attribution, and no analytical/interpretive text anywhere in output.

### Implementation for User Story 2

- [x] T013 [US2] Rewrite agents/scraper.md — update Role section to explicitly state "pure navigator, no analysis" and set model to composer-2-fast
- [x] T014 [US2] Rewrite agents/scraper.md — add Required Input section accepting the structured Scraping Brief (YAML) with all fields from the contract
- [x] T015 [US2] Rewrite agents/scraper.md — add Phase 1 (Initialization) with domain detection and output directory creation
- [x] T016 [US2] Rewrite agents/scraper.md — add Phase 2 (Crawl) with BFS algorithm, scope_filters enforcement, and same-domain constraint
- [x] T017 [US2] Rewrite agents/scraper.md — add table/data extraction logic: detect <table>, <dl>, repeated patterns → write as markdown files in tables/ with source URL header
- [x] T018 [US2] Rewrite agents/scraper.md — add page data extraction (title, headings, links, meta) → write JSON to pages/{slug}.json
- [x] T019 [P] [US2] Rewrite agents/scraper.md — add screenshot capture logic (full-page PNG) → screenshots/{slug}.png (conditional on deliverables.screenshots)
- [x] T020 [P] [US2] Rewrite agents/scraper.md — add accessibility snapshot capture → snapshots/{slug}.yaml (conditional on deliverables.accessibility_snapshots)
- [x] T021 [US2] Rewrite agents/scraper.md — add authentication execution section: interpret brief.auth and execute Playwright login steps before crawling
- [x] T022 [US2] Rewrite agents/scraper.md — add crawl-log.json generation with BFS traversal log (URL, timestamp, depth, status)
- [x] T023 [US2] Rewrite agents/scraper.md — add Handoff section with structured YAML return summary (domain, pages_crawled, artifacts counts, errors)
- [x] T024 [US2] Rewrite agents/scraper.md — remove ALL analysis/synthesis phases (current Phase 3), remove overview.md/journeys.md generation, remove site-purpose detection

**Checkpoint**: Agent produces only raw artifacts — no interpretation. Tables are properly extracted with source attribution.

---

## Phase 5: User Story 3 — Deterministic Web Analysis Skill (Priority: P2)

**Goal**: A comprehensive skill documenting Docker-based web analysis tools, following the k8s-troubleshoot pattern.

**Independent Test**: Copy any Docker command from the skill, run it against a public URL, and verify it produces the documented output format.

### Implementation for User Story 3

- [x] T025 [US3] Write .agents/skills/web-analysis/SKILL.md — frontmatter (name, description, tags), prerequisites section (Docker only)
- [x] T026 [US3] Write .agents/skills/web-analysis/SKILL.md — Lighthouse section: Docker command, output format (JSON/HTML), common flags, official docs link
- [x] T027 [P] [US3] Write .agents/skills/web-analysis/SKILL.md — pa11y section: Docker command, WCAG standards, output format, official docs link
- [x] T028 [P] [US3] Write .agents/skills/web-analysis/SKILL.md — sitespeed.io section: Docker command, metrics captured, output dashboard, official docs link
- [x] T029 [P] [US3] Write .agents/skills/web-analysis/SKILL.md — broken-link-checker section: Docker command, output format, recursive options, official docs link
- [x] T030 [P] [US3] Write .agents/skills/web-analysis/SKILL.md — security headers analysis section: curl-based Docker command, expected headers, scoring, OWASP reference
- [x] T031 [P] [US3] Write .agents/skills/web-analysis/SKILL.md — Wappalyzer CLI section: Docker command, technology categories detected, output format, official docs link
- [x] T032 [P] [US3] Write .agents/skills/web-analysis/SKILL.md — html-validate section: Docker command, rule configuration, output format, official docs link
- [x] T033 [US3] Write .agents/skills/web-analysis/SKILL.md — Tool Selection Guide section: decision matrix (which tool for which question)
- [x] T034 [US3] Write .agents/skills/web-analysis/SKILL.md — Combined Analysis section: docker-compose or script example running multiple tools
- [x] T035 [US3] Create .agents/skills/web-analysis/Dockerfile — multi-tool image with Lighthouse, pa11y, html-validate, broken-link-checker pre-installed

**Checkpoint**: All 7 tools documented with ready-to-run Docker commands. Dockerfile provides a convenience all-in-one image.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Consistency, cleanup, and documentation.

- [x] T036 [P] Verify commands/scrape-site.md references agents/scraper.md by name and passes the brief correctly
- [x] T037 [P] Verify agents/scraper.md has zero overlap with commands/scrape-site.md (no intent detection, no verification)
- [x] T038 [P] Verify .agents/skills/web-analysis/SKILL.md has zero overlap with agents/scraper.md (no Playwright, no navigation)
- [x] T039 Update asset-registry.yml with new scraper/command descriptions and add web-analysis skill entry
- [x] T040 Remove deprecated deliverables from old agent (overview.md, journeys.md generation) — confirmed removed in new agents/scraper.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS command and agent rewrite
- **US1 Command (Phase 3)**: Depends on Foundational (contract defined)
- **US2 Agent (Phase 4)**: Depends on Foundational (contract defined)
- **US3 Skill (Phase 5)**: No dependencies on other phases — can start anytime after Setup
- **Polish (Phase 6)**: Depends on Phases 3, 4, 5 all complete

### User Story Dependencies

- **US1 (Command)** and **US2 (Agent)**: Can be written in parallel after Foundational phase
- **US3 (Skill)**: Fully independent — can run in parallel with US1 and US2
- US1 and US2 integrate at runtime (command invokes agent) but are independently writable

### Parallel Opportunities

```
After Phase 2 (Foundational):
├── US1: Command rewrite (T005–T012) — single file
├── US2: Agent rewrite (T013–T024) — single file
└── US3: Skill creation (T025–T035) — single file + Dockerfile
```

All three user stories target different files and can be executed simultaneously.

---

## Implementation Strategy

### MVP First (US1 + US2)

1. Complete Phase 1: Setup (T001–T002)
2. Complete Phase 2: Foundational contract (T003–T004)
3. Complete Phase 3: Command (T005–T012)
4. Complete Phase 4: Agent (T013–T024)
5. **VALIDATE**: Run `/scrape-site` end-to-end on a test URL
6. Complete Phase 5: Skill (T025–T035)
7. Complete Phase 6: Polish (T036–T040)

### Parallel Strategy

With capacity for parallel work:
1. Setup + Foundational (sequential, fast)
2. Then simultaneously:
   - Stream A: Command rewrite (US1)
   - Stream B: Agent rewrite (US2)
   - Stream C: Skill creation (US3)
3. Polish after all streams complete

---

## Notes

- All three main deliverables (command, agent, skill) are separate markdown files with zero code dependencies
- The "contract" is conceptual (YAML schema documented in the agent's input section), not a runtime-validated schema
- The agent model choice (`composer-2-fast`) is specified in the agent's frontmatter
- Docker commands in the skill should use pinned image tags for reproducibility
