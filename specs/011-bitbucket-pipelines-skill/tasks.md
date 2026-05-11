# Tasks: Bitbucket Pipelines Skill

**Input**: Design documents from `/specs/011-bitbucket-pipelines-skill/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, quickstart.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create skill structure and documentation files

- [ ] T001 Create resources/bitbucket-pipelines/ directory structure
- [ ] T002 Write main SKILL.md file (< 200 lines)
- [ ] T003 [P] Create resource file: get-started.md

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Create core documentation structure

- [ ] T004 Write bitbucket-pipelines.yml configuration reference
- [ ] T005 [P] Create resource file: pipes.md
- [ ] T006 [P] Create resource file: variables-secrets.md
- [ ] T007 [P] Create resource file: view-pipeline.md

---

## Phase 3: User Story 1 - Learn Bitbucket Pipelines Basics (Priority: P1) 🎯 MVP

**Goal**: Create documentation explaining core Bitbucket Pipelines concepts.

**Independent Test**: Read the SKILL.md and understand pipelines basics.

### Implementation

- [ ] T008 [P] [US1] Write core concepts in SKILL.md
- [ ] T009 [US1] Add bitbucket-pipelines.yml reference section
- [ ] T010 [US1] Add pipe examples and usage guide

**Checkpoint**: Core documentation complete - users can learn basics

---

## Phase 4: User Story 2 - Use Bitbucket Pipelines UI (Priority: P1) 🎯

**Goal**: Document UI wizard workflow for pipeline configuration.

**Independent Test**: Follow documented steps to configure a pipeline.

### Implementation

- [ ] T011 [P] [US2] Write UI wizard step-by-step guide
- [ ] T012 [US2] Document template selection process
- [ ] T013 [US2] Add YAML editor customization examples

**Checkpoint**: UI configuration documented - users can use wizard

---

## Phase 5: User Story 3 - Configure Pipes and Variables (Priority: P2)

**Goal**: Enable documentation for third-party integrations and secrets.

**Independent Test**: Configure AWS S3 deployment using pipe doc + variables.

### Implementation

- [ ] T014 [P] [US3] Write pipe usage guide in resources/
- [ ] T015 [US3] Document secure variable management
- [ ] T016 [US3] Add variables scope explanation (workspace/repo/dep)

**Checkpoint**: Advanced features documented - users can configure integrations

---

## Phase N: Polish & Cross-Cutting Concerns

**Purpose**: Finalize skill and ensure all references are complete

- [ ] T017 [P] Update SKILL.md line count verification (< 200 lines)
- [ ] T018 [P] Add resource references in SKILL.md
- [ ] T019 [P] Validate all external links for Bitbucket docs
- [ ] T020 [P] Create quickstart.md summary

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
- **Polish (Final Phase)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational - No dependencies
- **User Story 2 (P1)**: Can start after Foundational - Independent from US1
- **User Story 3 (P2)**: Depends on US1 completion (pipes require basic knowledge)

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational tasks marked [P] can run in parallel
- User Stories 1 and 2 can be worked on in parallel by different team members

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: SKILL.md complete with core concepts
5. Check line count (< 200 lines)

### Incremental Delivery

1. Complete Setup + Foundational → Core structure ready
2. Add User Story 1 → Basic documentation complete
3. Add User Story 2 → UI wizard documentation added
4. Add User Story 3 → Pipelines and variables complete
5. Polish → Finalized skill with all references

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- SKILL.md must stay under 200 lines
- Resources folder contains supporting detailed documentation
