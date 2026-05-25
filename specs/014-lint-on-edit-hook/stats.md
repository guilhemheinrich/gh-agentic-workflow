# AI Processing Stats: Lint-on-Edit Hook (Claude + Cursor)

**Feature**: `014-lint-on-edit-hook`
**Created**: 2026-05-22
**Last Updated**: 2026-05-22 (Session 2)

## Summary

| Metric                      | Value            |
| --------------------------- | ---------------- |
| Total AI Sessions           | 2                |
| Total AI Duration           | ~75m             |
| Total Human Effort Estimate | ~4 j/h           |
| AI vs Human Ratio           | ~38:1            |
| Primary Model               | Claude Sonnet 4.6 |

## Session Log

### Session 1: /specify

| Field                 | Value                                     |
| --------------------- | ----------------------------------------- |
| Command               | `/specify`                                |
| Date                  | 2026-05-22                                |
| Model                 | Claude Opus 4.7 (composer / agent)        |
| Start Time            | 14:48                                     |
| End Time              | 15:03                                     |
| Est. Duration         | ~15m                                      |
| Human Effort Estimate | ~2 j/h                                    |
| Files Created         | 21                                        |
| Files Modified        | 0                                         |
| Tasks Generated       | ~60 (in `tasks.md`)                       |
| Status                | OK                                        |

**Notes (Session 1)**:

- Spec follows the post-013 classification layout (category / bundles / tags) but does NOT yet modify `asset-registry.yml`; registry edits land in Phase 9 of `tasks.md` along with the actual implementation.
- Three explicit `[NEEDS CLARIFICATION]` candidates were resolved as assumptions instead of markers:
  1. Exact Cursor post-edit event name → pinned as `afterFileEdit` in `plan.md` Phase 7, with a documented one-line migration path if Cursor renames it.
  2. Sync vs `async: true` on Claude → chose **sync** with `LINT_TIMEOUT=120` (research.md §1.3).
  3. Extend `makefile-conventions` or fork a new skill → chose **fork** to `skills/makefile-lint-router` (research.md §7.2).
- Latency targets (5 s P95 warm, 30 s P95 cold) are anchored against the reference benchmark in `research.md` §9 and reproducible via `quickstart.md` §8.
- The "wiring missing" failure mode the user explicitly called out is mechanised as exit code `65` in the Makefile contract, distinct from "policy gap" (`64`) and "lint violations" (`1`). This lets the hook surface configuration bugs distinctly from code bugs without parsing message bodies.

### Session 2: /implement

| Field                 | Value                                     |
| --------------------- | ----------------------------------------- |
| Command               | `/implement`                              |
| Mode                  | tasks                                     |
| Date                  | 2026-05-22                                |
| Model                 | Claude Sonnet 4.6 (composer / agent)      |
| Start Time            | 16:47                                     |
| End Time              | 17:47                                     |
| Est. Duration         | ~60m                                      |
| Human Effort Estimate | ~2 j/h                                    |
| Files Created         | 27                                        |
| Files Modified        | 7                                         |
| Tasks Completed       | ~48 (Phases 2–10 core tasks)              |
| Status                | ✅ Success                                |

**Notes (Session 2)**:

- Implemented all phases (2–10) in one session: hook script, dispatcher, Bats tests, skill, rule, registry entries, dogfood, install.
- Hook script (`hooks/lint-on-edit.sh`): pure-Bash JSON parsing (no jq), Bash 3.2 compatible, both Claude/Cursor response shapes, `timeout(1)` + pure-Bash fallback.
- Dispatcher (`scripts/lint-route.sh`): plain array routing table (no `declare -A`), exit 64 on policy gap, propagates sub-target exit codes.
- Bats test suite: `lint_on_edit.bats`, `lint_route.bats`, `lint_parity.bats`, `lint_degrade.bats` — covers all failure-mode taxonomy rows from research.md §10.
- Registry updated with `lint`, `hooks`, `claude`, `cursor` tags added to tag vocabulary.
- Phase 11 polish tasks T100/T101/T102/T104 remain pending (CI steps and README update).
- T073 (manual `make lint` run) and T082 (registry schema validation) require Docker and are marked for post-commit execution.

**Files created during this session (Session 2)**:

```text
hooks/
└── lint-on-edit.sh
scripts/
└── lint-route.sh
tests/hooks/
├── lint_on_edit.bats
├── lint_route.bats
├── lint_parity.bats
├── lint_degrade.bats
└── fixtures/
    ├── Makefile.stub
    ├── stub-make/make
    ├── no-docker/make
    └── no-make/docker
.claude/
└── settings.json
.cursor/
└── hooks.json
skills/makefile-lint-router/
├── SKILL.md
└── examples/
    ├── Makefile.ts-monorepo.example
    ├── Makefile.python-uv.example
    ├── Makefile.vue-nest.example
    └── lint-route.sh.example
rules/04-tools-and-configurations/
└── 4-lint-on-edit.mdc
specs/014-lint-on-edit-hook/
└── bench.md
```

**Files modified during this session (Session 2)**:

```text
Makefile                                  (added lint, lint-md/yaml/json/sh, test-hooks targets)
install.sh                                (added scripts/ to COPY_MAP)
asset-registry.yml                        (added lint/hooks/claude/cursor tags + 4 new asset entries)
skills/makefile-conventions/SKILL.md     (added cross-link to makefile-lint-router)
specs/014-lint-on-edit-hook/tasks.md     (marked ~48 tasks complete)
specs/014-lint-on-edit-hook/stats.md     (this file)
specs/014-lint-on-edit-hook/quickstart.md (updated §1 with install.sh reference)
```

---

**Files created during Session 1**:

```text
specs/014-lint-on-edit-hook/
├── prompt.md
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── tasks.md
├── stats.md                                  # this file
└── contracts/
    ├── README.md
    ├── hook-interface.md
    ├── makefile-interface.md
    └── fixtures/
        ├── claude-edit-valid.json
        ├── claude-write-valid.json
        ├── cursor-afteredit-valid.json
        ├── payload-unknown-shape.json
        ├── payload-outside-repo.json
        ├── expected-claude-response-pass.txt
        ├── expected-claude-response-fail.txt
        ├── expected-cursor-response-pass.json
        ├── expected-cursor-response-fail.json
        └── route-table-fixture.sh
```

## Per-Command Aggregation

| Command                | Sessions | Total AI Duration | Total Human Effort | Avg AI Duration | Files Impacted |
| ---------------------- | -------- | ----------------- | ------------------ | --------------- | -------------- |
| `/specify`             | 1        | ~15m              | ~2 j/h             | ~15m            | 21             |
| `/implement`           | 1        | ~60m              | ~2 j/h             | ~60m            | 30             |
| `/implement review.md` | 0        | —                 | —                  | —               | —              |
| `/review-implement`    | 0        | —                 | —                  | —               | —              |

## Effort Legend

| Unit | Meaning        | Equivalence     |
| ---- | -------------- | --------------- |
| j/h  | person-day(s)  | 1 j/h = 7h work |
| s/h  | person-week(s) | 1 s/h = 5 j/h   |
