# Tasks: Release and Versioning Standards

## Phase 1: Setup (Spec Artifacts)

**Purpose**: Create the specification folder and all planning documents

- [ ] T001 Create spec folder `specs/002-release-and-versioning/` with prompt.md, spec.md, plan.md, tasks.md, stats.md, quickstart.md
- [ ] T002 Create feature branch `feat/002-release-and-versioning`

## Phase 2: Skill 1 — `app-version-surface`

**Purpose**: Define the organization-wide standard for version metadata exposure and display

- [ ] T003 Create `skills/app-version-surface/SKILL.md` with YAML frontmatter
- [ ] T004 Write canonical JSON version contract section (mandatory + optional fields)
- [ ] T005 Write display format standard section (`version+commit`)
- [ ] T006 Write UI display rules section (Level 1 user-visible, Level 2 technical panel)
- [ ] T007 Write ingestion modes section (build-time, runtime endpoint, hybrid)
- [ ] T008 Write aggregated version contract section for multi-component applications
- [ ] T009 Write implementation checklist for application projects
- [ ] T010 Write security and observability checklist
- [ ] T011 Write anti-patterns section

**Checkpoint**: Skill 1 complete — all version surfacing guidance available to agents

## Phase 3: Skill 2 — `semantic-release-js-ts-pipeline`

**Purpose**: Define the standard release automation pipeline for JS/TS projects

- [ ] T012 Create `skills/semantic-release-js-ts-pipeline/SKILL.md` with YAML frontmatter
- [ ] T013 Write commit convention mapping section (feat→minor, fix→patch, BREAKING→major)
- [ ] T014 Write plugin recommendation matrix (minimum viable, standard app, npm package, opt-in)
- [ ] T015 Write reference `.releaserc` configurations for each project type
- [ ] T016 Write CI pipeline architecture section (dry-run on PR, release on merge)
- [ ] T017 Write branch governance section (main, next, beta)
- [ ] T018 Write version surfacing integration section (link to skill 1)
- [ ] T019 Write implementation checklist
- [ ] T020 Write anti-patterns section

**Checkpoint**: Skill 2 complete — all semantic-release guidance available to agents

## Phase 4: Command — `/spec-release-and-versioning`

**Purpose**: Create the Speckit command for producing versioning specifications

- [ ] T021 Create `commands/spec-release-and-versioning.md` with YAML frontmatter
- [ ] T022 Write command behavior and usage section
- [ ] T023 Write Speckit spec template with all required sections
- [ ] T024 Write prompt templates (standard and directive variants)
- [ ] T025 Write skill cross-references section

**Checkpoint**: Command complete — teams can generate versioning specs

## Phase 5: Polish & Cross-Cutting Concerns

- [ ] T026 [P] Update `skills-lock.json` if needed for new skills
- [ ] T027 [P] Write quickstart.md for the spec
- [ ] T028 Run validation: verify all files follow repository conventions

## Dependency Graph

```text
Setup (Phase 1) → Skill 1 (Phase 2) → Skill 2 (Phase 3) → Command (Phase 4) → Polish (Phase 5)
                                         ↑ can start in parallel with Phase 2
```

Note: Phases 2 and 3 can be implemented in parallel since they are independent skills. Phase 4 depends on both skills being defined (it references them). Phase 5 is final validation.

## Summary

- Total tasks: 28
- By priority: P0=0, P1=25 (all core tasks), P2=3 (polish)
- Estimated effort: ~2-3 hours for an agent, ~2 j/h for a human
