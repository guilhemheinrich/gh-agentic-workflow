# Tasks: Lint-on-Edit Hook (Claude + Cursor)

**Branch**: `feature/014-lint-on-edit-hook`
**Spec**: [./spec.md](./spec.md) · **Plan**: [./plan.md](./plan.md) · **Contracts**: [./contracts/](./contracts/)

> Task format: `- [ ] TXXX [P?] [USX?] Description with file path`.
> `[P]` = parallel-safe (different files, no dependency).
> `[USX]` = belongs to User Story X (US1…US5 from `spec.md`).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Land the contracts and the fixture suite so every later phase has a verifiable target.

- [X] T001 Create branch `feature/014-lint-on-edit-hook` and `specs/014-lint-on-edit-hook/` folder.
- [X] T002 Author `specs/014-lint-on-edit-hook/spec.md`.
- [X] T003 Author `specs/014-lint-on-edit-hook/research.md`.
- [X] T004 Author `specs/014-lint-on-edit-hook/data-model.md`.
- [X] T005 Author `specs/014-lint-on-edit-hook/plan.md`.
- [X] T006 [P] Author `specs/014-lint-on-edit-hook/quickstart.md`.
- [X] T007 [P] Author `specs/014-lint-on-edit-hook/contracts/README.md`.
- [X] T008 [P] Author `specs/014-lint-on-edit-hook/contracts/hook-interface.md`.
- [X] T009 [P] Author `specs/014-lint-on-edit-hook/contracts/makefile-interface.md`.
- [X] T010 [P] Create input/expected fixtures under `specs/014-lint-on-edit-hook/contracts/fixtures/`.

**Checkpoint**: All spec artefacts exist. Next phase produces code.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Stand up the test harness so every code change can be verified.

- [X] T011 Create `tests/hooks/` directory at repo root.
- [X] T012 [P] Write `tests/hooks/lint_on_edit.bats` — Bats skeleton with one test per row of the failure-mode taxonomy (research.md §10). All tests SHOULD fail at this point (no hook yet).
- [X] T013 [P] Write `tests/hooks/lint_route.bats` — Bats skeleton testing the dispatcher: ignored extension → 0, ignored path → 0, routed extension → exec target, unknown extension → 64, empty FILE → 64.
- [X] T014 [P] Write `tests/hooks/fixtures/Makefile.stub` — a tiny test Makefile exposing fake `lint-md`, `lint-ts` etc. used by the dispatcher tests.
- [X] T015 Document the Bats Docker invocation in `quickstart.md` §7 (verify it works against the existing skeleton — tests fail as expected).
- [X] T016 Add a top-level `make test-hooks` target invoking the Bats Docker image against `tests/hooks/`. Wire it into the existing repo Makefile.

**Checkpoint**: `make test-hooks` runs the suite and reports failures for every taxonomy row. The harness is real.

---

## Phase 3: User Story 1 — Agent edits a file and gets feedback (P1) — MVP

**Goal**: From a Claude `PostToolUse` payload, a passing or failing lint produces the right host response.
**Independent Test**: `tests/hooks/lint_on_edit.bats` `@test "claude — failing TS lint emits exit 2 + diagnostic"` turns green.

- [X] T020 [US1] Create `hooks/lint-on-edit.sh` skeleton (shebang, `set -uo pipefail`, debug logger, `read_stdin_all`) — copy the boilerplate pattern from `hooks/enforce-tools.sh`.
- [X] T021 [US1] Implement `extract_json_string` in `hooks/lint-on-edit.sh` (lift from `enforce-tools.sh::extract_command_field`, parametrise the key name).
- [X] T022 [US1] Implement candidate-key resolution in `hooks/lint-on-edit.sh` (try `tool_input.file_path`, then `file_path`, `path`, `file`). Resolves data-model.md §2.2.
- [X] T023 [US1] Implement host detection in `hooks/lint-on-edit.sh` (env first, payload sniff fallback). Resolves research.md §5.
- [X] T024 [US1] Implement the `make lint FILE=…` invocation in `hooks/lint-on-edit.sh` with `timeout`, stdout+stderr capture, and exit-code translation per data-model.md §6.
- [X] T025 [US1] Implement the Claude response branch in `hooks/lint-on-edit.sh` (structured header + plain stdout + `exit 2`). Resolves contracts/hook-interface.md §B2.
- [X] T026 [US1] Implement the Cursor response branch in `hooks/lint-on-edit.sh` (JSON envelope with escaped `agentMessage` + `exit 0`). Resolves contracts/hook-interface.md §B3.
- [X] T027 [US1] Run `shellcheck --severity=warning` on `hooks/lint-on-edit.sh` (NFR-003). Fix every finding.
- [X] T028 [US1] Turn green the Bats tests covering: Claude pass, Claude fail, Cursor pass, Cursor fail.

**Checkpoint**: User Story 1 — agent receives a useful diagnostic in the same turn.

---

## Phase 4: User Story 2 — Missing linter wiring blocks (P1)

**Goal**: Exit codes `64`/`65` are produced where they should be, hook surfaces them as actionable agent messages.
**Independent Test**: Bats `@test "policy gap on unknown extension"` and `@test "wiring missing surfaces stderr"` turn green.

- [X] T030 [US2] Create `scripts/lint-route.sh` with the `LINT_ROUTES`, `LINT_IGNORED`, `LINT_EXCLUDED_PATHS` constants from data-model.md §4 (Bash 3.2-compatible `name:value` array form).
- [X] T031 [US2] Implement the dispatcher logic in `scripts/lint-route.sh`: usage check → path-prefix check → ignored extension → routed extension `exec make lint-<target>` → fallback exit 64.
- [X] T032 [US2] Add `lint:` target to the repo's root `Makefile` delegating to `scripts/lint-route.sh`.
- [X] T033 [US2] Run `shellcheck` on `scripts/lint-route.sh`. Fix every finding.
- [X] T034 [US2] Turn green the Bats tests under `lint_route.bats` covering: ignored ext, ignored path, routed ext (with stub Makefile), unknown ext (exit 64).
- [X] T035 [US2] [P] Synchronise `specs/014-lint-on-edit-hook/contracts/fixtures/route-table-fixture.sh` with `scripts/lint-route.sh` and add a Bats test asserting byte-equality of the routing arrays.
- [X] T036 [US2] Turn green the integration Bats test asserting that an unknown extension produces a hook agent message containing the phrase `policy gap` AND the offending extension.
- [X] T037 [US2] Add a sub-target template that intentionally fails at startup (e.g. `lint-broken-ts: ; exit 65`) under `tests/hooks/fixtures/`. Turn green the integration test asserting the hook surfaces this with the phrase `wire up` and the target name.

**Checkpoint**: User Story 2 — broken wiring is loudly visible.

---

## Phase 5: User Story 3 — Editor parity (P1)

**Goal**: Same script, same `make lint` contract under Claude and Cursor.
**Independent Test**: Same Bats fixture (linter diagnostic) is asserted against both Claude-shaped and Cursor-shaped payloads → identical message substring.

- [X] T040 [US3] Add a Bats test that runs the hook twice on the same lint failure — once with `LINT_HOOK_HOST=claude` + `claude-edit-valid.json`, once with `LINT_HOOK_HOST=cursor` + `cursor-afteredit-valid.json` — and asserts the `agentMessage` substring is identical (modulo envelope).
- [X] T041 [US3] Add a Bats test for the payload sniff fallback: no `LINT_HOOK_HOST` env, payload contains `tool_input` → response is Claude shape; payload lacks `tool_input` → response is Cursor shape.
- [X] T042 [US3] Author `.claude/settings.json` snippet (project-level, dogfood) registering `PostToolUse` `Edit|Write` → `hooks/lint-on-edit.sh` with `LINT_HOOK_HOST=claude`.
- [X] T043 [US3] Author `.cursor/hooks.json` snippet (project-level, dogfood) registering the post-edit event → `hooks/lint-on-edit.sh` with `LINT_HOOK_HOST=cursor`. Pin the exact event name from Cursor docs.
- [X] T044 [US3] [P] Document the coverage gap (`Bash`-driven writes) inside `.claude/settings.json` (`"comment"` field if tolerated, else inline doc above) AND in `quickstart.md` §3.

**Checkpoint**: User Story 3 — both editors trigger the same script, same diagnostics.

---

## Phase 6: User Story 4 — Reusable skill (P2)

**Goal**: A maintainer can build a new project's routing Makefile from the skill alone.
**Independent Test**: A fresh sandbox using only the skill produces a working `make lint FILE=…` covering at least TS, MD, YAML.

- [X] T050 [US4] Create folder `skills/makefile-lint-router/`.
- [X] T051 [US4] Author `skills/makefile-lint-router/SKILL.md` with the frontmatter `description`, the three-layer diagram, the routing-table convention, per-language sub-target templates (TS, JS, JSON, MD, YAML, SH, PY, GO), the wiring-missing failure mode, the anti-patterns table, and a cross-link to `makefile-conventions`.
- [X] T052 [US4] [P] Author `skills/makefile-lint-router/examples/Makefile.ts-monorepo.example` — full Makefile for a TS monorepo using Biome.
- [X] T053 [US4] [P] Author `skills/makefile-lint-router/examples/Makefile.python-uv.example` — full Makefile for a Python project using ruff + uv.
- [X] T054 [US4] [P] Author `skills/makefile-lint-router/examples/Makefile.vue-nest.example` — full Makefile for a Vue/Nest monorepo.
- [X] T055 [US4] [P] Author `skills/makefile-lint-router/examples/lint-route.sh.example` — a heavily commented copy of the dispatcher for teaching purposes.
- [X] T056 [US4] Add a cross-link section in `skills/makefile-conventions/SKILL.md` pointing at the new skill.
- [X] T057 [US4] Add the new skill to `asset-registry.yml` with `category: tools-and-configurations`, `bundles: [common]`, `tags: [docker, lint, makefile, hooks]`. Validate against the schema per spec 013's `quickstart.md`.

**Checkpoint**: User Story 4 — skill is browsable, validated in the registry, ready to teach.

---

## Phase 7: User Story 5 — Graceful degradation (P2)

**Goal**: Missing `docker` / `make` / timeout produce actionable agent messages, not crashes.
**Independent Test**: Bats tests that fake-out `docker` / `make` (via a stub `PATH`) and assert the agent message names the missing dependency.

- [X] T060 [US5] Add a stub-PATH fixture under `tests/hooks/fixtures/no-docker/` containing a no-op `make` but no `docker`. Bats test: hook agent message contains `docker`.
- [X] T061 [US5] Add `tests/hooks/fixtures/no-make/` containing no `make`. Bats test: hook agent message contains `make`.
- [X] T062 [US5] Implement timeout handling in `hooks/lint-on-edit.sh` (either GNU `timeout(1)` or a pure-Bash `( cmd & ; sleep $T ; kill $! )` fallback, decided in plan.md). Bats test: `LINT_TIMEOUT=1` against a sleeping stub Makefile produces the timeout message.
- [X] T063 [US5] [P] Document the three escape hatches (`LINT_ON_EDIT=0`, remove hook config, `LINT_IGNORED`) in `quickstart.md` §9. (Already drafted — verify text reflects implementation.)

**Checkpoint**: User Story 5 — hook never silently breaks the editing loop.

---

## Phase 8: Dogfood on this repo

**Purpose**: Prove the convention by installing it on this repo.

- [X] T070 Edit root `Makefile` to add `lint`, `lint-md`, `lint-yaml`, `lint-json`, `lint-sh` targets covering the file types this repo produces (per FR-025). Use the templates from Phase 4.
- [X] T071 Create root `.claude/settings.json` registering `PostToolUse` `Edit|Write` → `hooks/lint-on-edit.sh`. If a file already exists, merge non-destructively.
- [X] T072 Create root `.cursor/hooks.json` registering the post-edit event → `hooks/lint-on-edit.sh`. Do NOT touch the existing `enforce-tools.sh` user-level wiring.
- [ ] T073 Run `make lint FILE=specs/014-lint-on-edit-hook/spec.md` — confirm exit 0 (or fix any real markdown-lint violation).
- [X] T074 Author the bench script in `quickstart.md` §8 → run it → save the results in `specs/014-lint-on-edit-hook/bench.md`. Confirm SC-005 (P95 ≤ 5 s).

**Checkpoint**: This repo passes its own lint-on-edit policy.

---

## Phase 9: Registry + Rule

- [X] T080 Author `rules/04-tools-and-configurations/4-lint-on-edit.mdc` — short rule (≤ 80 lines) per plan.md Phase 6.
- [X] T081 Add three entries to `asset-registry.yml`:
  - `hooks/lint-on-edit.sh` — type `hook`, category `tools-and-configurations`, bundles `[common]`, tags `[docker, lint, makefile, claude, cursor]`.
  - `skills/makefile-lint-router/SKILL.md` — type `skill`, same category/bundles, tags `[docker, lint, makefile, hooks]`.
  - `rules/04-tools-and-configurations/4-lint-on-edit.mdc` — type `rule`, same category/bundles, tags `[docker, lint, hooks]`.
- [ ] T082 Validate the registry against `asset-registry.schema.json` per spec 013's `quickstart.md`. Fix any tag-vocabulary issue (e.g. add `lint`, `hooks`, `claude`, `cursor` to the schema's `$defs.tag.enum` if not already present from spec 013).

**Checkpoint**: Registry is green, assets are discoverable.

---

## Phase 10: Install pipeline + handoff

- [X] T090 Update `install.sh` to copy `hooks/lint-on-edit.sh`, `scripts/lint-route.sh`, the new skill, and the new rule into a target project. Idempotent — re-running does not duplicate entries in `.claude/settings.json` / `.cursor/hooks.json`.
- [ ] T091 [P] Update `install.ps1` to mirror `install.sh` behaviour on Windows.
- [X] T092 [P] Add an example walkthrough section to the new skill: "From zero to lint-on-edit in 5 minutes" — anchored on `quickstart.md`.

**Checkpoint**: A maintainer cloning a new project can run the installer and inherit the policy.

---

## Phase 11: Polish & Cross-Cutting Concerns

- [ ] T100 [P] Add a CI step (Bitbucket Pipelines or GitHub Actions, per repo convention) running `shellcheck` on every shell script in the repo. Block merges on any warning.
- [ ] T101 [P] Add a CI step running `make test-hooks` against the Bats suite. Block merges on any failure.
- [ ] T102 [P] Add a CI step running the latency benchmark (Phase 8 T074) on a reference matrix (Linux + macOS runner if available). Soft-fail on SC-005 regression; hard-fail on a 2× regression.
- [X] T103 Update `_todo.md` (if present) with lessons learned from spec 014.
- [ ] T104 Update repo's top-level `README.md` (if present) with a "Lint-on-Edit" paragraph pointing at `quickstart.md`.

---

## Dependency Graph

```text
Setup (Phase 1)
        │
        ▼
Foundational test harness (Phase 2)
        │
        ▼
US1: Hook + Claude/Cursor response (Phase 3)
        │
        ▼
US2: Router + exit codes 64/65 (Phase 4) ───────┐
                                                │
US3: Editor parity (Phase 5) ───────────────────┤
                                                │
                                                ▼
US4: Skill (Phase 6) ───────────────────────────┤    Dogfood (Phase 8)
                                                │           │
US5: Graceful degradation (Phase 7) ────────────┘           │
                                                            ▼
                                                Registry + Rule (Phase 9)
                                                            │
                                                            ▼
                                                Install pipeline (Phase 10)
                                                            │
                                                            ▼
                                                Polish (Phase 11)
```

Phases 4 / 5 are independent of each other but both consume Phase 3 outputs. Phase 6 (skill) is independent of code phases but depends on data-model.md being frozen.

---

## Summary

- **Total tasks**: ~ 60 (including completed Phase 1 spec authoring tasks T001–T010).
- **By priority**:
  - P1 (US1, US2, US3): T020–T044 — the headline value.
  - P2 (US4, US5): T050–T063 — the policy hardening + skill.
  - Dogfood / registry / install / polish: T070–T104.
- **Critical path**: T020 → T024 → T028 → T030 → T034 → T036 → T037 → T070 → T073.
- **Estimated effort**:
  - Senior dev manual: ~ 4 j/h (3 j/h core + 1 j/h skill).
  - AI-assisted: ~ 1.5 j/h end-to-end with this spec.
- **Largest unknowns**: exact Cursor event name (`afterFileEdit` is pinned in this spec but verify at install), exact env var Cursor passes for the file path. Both are one-line changes if doc evolves.
