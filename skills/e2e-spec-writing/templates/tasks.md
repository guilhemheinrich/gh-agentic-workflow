# Tasks: E2E [description]

Format: `- [ ] TXXX [P?] [USN?] Description with file path`
([P] = parallelizable, [USN] = linked user story)

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Configure Playwright fixtures for [context]
- [ ] T002 [P] Create shared helpers in tests/e2e/helpers/

## Phase 2: Data-TestID (Only allowed app modification)

- [ ] T003 [P] Add data-testid to [component] in [path]
- [ ] T004 [P] Add data-testid to [component] in [path]

**Checkpoint**: All data-testid in place, app otherwise unchanged

## Phase 3: E2E Tests - [User Story 1]

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
