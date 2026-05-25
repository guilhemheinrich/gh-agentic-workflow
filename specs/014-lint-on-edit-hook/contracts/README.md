# Contracts — Lint-on-Edit Hook

This folder pins the **runtime contracts** between the four moving parts of the feature. Each contract is owned by one document, and each fixture proves one rule of one contract.

---

## Interface documents

| Document                              | Owns the contract between                |
| ------------------------------------- | ---------------------------------------- |
| [hook-interface.md](./hook-interface.md)         | Agent host (Claude / Cursor) ↔ `hooks/lint-on-edit.sh` |
| [makefile-interface.md](./makefile-interface.md) | `hooks/lint-on-edit.sh` ↔ root `Makefile` (`make lint`) |

---

## Fixtures

Located under [`fixtures/`](./fixtures/). Each fixture serves a specific assertion in the Bats test suite (under `tests/hooks/` once Phase 1 of `plan.md` lands).

### Input fixtures

| Fixture                          | Represents                                                              | Used by                              |
| -------------------------------- | ----------------------------------------------------------------------- | ------------------------------------ |
| `claude-edit-valid.json`         | Claude `PostToolUse` for an `Edit` tool, file inside the repo.          | Hook tests — Claude happy/failing path |
| `claude-write-valid.json`        | Claude `PostToolUse` for a `Write` tool, file inside the repo.          | Hook tests — Write coverage          |
| `cursor-afteredit-valid.json`    | Cursor post-edit event, file inside the repo.                            | Hook tests — Cursor parity           |
| `payload-unknown-shape.json`     | A payload with no candidate key — should silently no-op.                | Hook tests — robustness              |
| `payload-outside-repo.json`      | A payload with `file_path` outside the repo root — should silently no-op. | Hook tests — boundary                |
| `route-table-fixture.sh`         | A standalone copy of `scripts/lint-route.sh`'s routing arrays.          | Dispatcher tests                     |

### Expected-output fixtures

| Fixture                                  | Expected hook behaviour                                                            |
| ---------------------------------------- | ---------------------------------------------------------------------------------- |
| `expected-claude-response-pass.txt`      | Empty stdout + exit code `0`.                                                       |
| `expected-claude-response-fail.txt`      | Stdout begins with `[lint-on-edit] file=… ext=… target=… code=…\n\n…` + exit `2`.   |
| `expected-cursor-response-pass.json`     | Empty stdout + exit code `0`.                                                       |
| `expected-cursor-response-fail.json`     | JSON envelope `{permission: "allow", continue: true, agentMessage: "…"}` + exit `0`. |

---

## Negative fixtures — what each one proves

| Fixture                          | Rule it enforces                                                                                  | FR / SC reference |
| -------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------- |
| `payload-unknown-shape.json`     | Hook does NOT crash on an unrecognised payload; emits no agent message.                            | research.md §2.3  |
| `payload-outside-repo.json`      | Hook does NOT lint files outside the repo root (e.g. `~/.zshrc`).                                  | FR-003            |
| (Bats-driven, no fixture)        | `LINT_ON_EDIT=0` short-circuits to silent regardless of payload.                                   | FR-007            |
| (Bats-driven, no fixture)        | Extension in `LINT_IGNORED` → silent.                                                              | FR-012, SC-003    |
| (Bats-driven, no fixture)        | Extension in neither list → policy-gap message.                                                    | FR-013, SC-004    |
| (Bats-driven, no fixture)        | Routed extension but sub-target fails at invoke → wiring-missing message.                           | FR-014, SC-002    |

The "Bats-driven, no fixture" rows are tests that need no input file beyond a synthetic Makefile fixture; the Makefile fixture lives under `tests/hooks/fixtures/` and is not duplicated here.

---

## Source of truth

- The hook contract is **derived from**, not equal to, the Claude / Cursor docs. If the docs change, update [hook-interface.md](./hook-interface.md) and one of the JSON fixtures, then re-run Bats.
- The Makefile contract is **owned by this repo** — exit codes `64`/`65` are our convention, documented in [makefile-interface.md](./makefile-interface.md) and propagated by the `makefile-lint-router` skill.
