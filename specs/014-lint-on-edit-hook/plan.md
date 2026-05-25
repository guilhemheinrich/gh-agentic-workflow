# Implementation Plan: Lint-on-Edit Hook (Claude + Cursor)

**Branch**: `feature/014-lint-on-edit-hook` | **Date**: 2026-05-22 | **Spec**: [./spec.md](./spec.md)

---

## Summary

Ship a **distributable bundle** that wires a deterministic lint-on-edit feedback loop into both Claude Code and Cursor by:

1. A single, pure-Bash hook script (`hooks/lint-on-edit.sh`) that reads the host's JSON payload, resolves the touched file to a repo-relative path, calls `make lint FILE=…`, and translates the result into the host's native agent-feedback channel.
2. A **routing Makefile pattern** (`make lint` → `scripts/lint-route.sh` → `make lint-<ext>`) that lives at the project root and dispatches to per-language Dockerised linters.
3. Pre-defined exit codes (`64` = policy gap, `65` = wiring missing) that let the hook distinguish "code has lint errors" from "your Makefile is misconfigured" — the second case is the **non-silent** failure the user explicitly requested.
4. A new skill (`skills/makefile-lint-router/`) that teaches maintainers how to write the routing Makefile properly, with copy-pasteable per-language sub-target templates.
5. Claude Code (`PostToolUse` matcher `Edit|Write`) and Cursor (post-edit event) configuration snippets, both pointing at the same script and the same `make lint` contract.
6. Dogfood on this repo: a working `lint`, `lint-md`, `lint-yaml`, `lint-json`, `lint-sh` target covering the file types this repository actually produces.

Spec 013 (registry classification) is assumed merged before this one; the new assets land with the right `category`, `bundles`, `tags` from day one.

---

## Technical Context

| Aspect             | Decision                                                                                                              |
| ------------------ | --------------------------------------------------------------------------------------------------------------------- |
| **Language**       | Bash (POSIX-compatible to Bash 3.2 for macOS) for the hook + the dispatcher. GNU Make 3.81+ for the Makefile additions. |
| **Dependencies**   | `bash`, `make`, `docker`. **No** `jq`, `yq`, `python`. Same baseline as `hooks/enforce-tools.sh`.                     |
| **Linter runtime** | Inside Docker containers, per service: Biome (TS/JS/JSON), markdownlint (MD/MDC), yamllint (YML/YAML), shellcheck (SH). Each project picks its own — these are the **defaults** documented in the skill. |
| **Validation**     | `shellcheck` Dockerised, plus a Bats (Bash testing) suite under `tests/hooks/` documented in `quickstart.md`. Bats run via Docker image `bats/bats:latest`. |
| **Schemas**        | The hook payload contract is documented as fixture JSONs under `contracts/fixtures/`. Not a JSON Schema — the source of truth is the host's docs, we just pin the shape we depend on. |
| **Project type**   | Asset library refactor + new asset bundle (hook, skill, Makefile pattern, configs). No new runtime app.               |
| **Target hosts**   | Claude Code (`PostToolUse`), Cursor (post-edit event). Other agents (Aider, Continue) can adopt by emitting `LINT_HOOK_HOST=<their-name>`. |

---

## Architecture Decision (high level)

**Three-layer separation**, deliberately rigid:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 1 — Deterministic trigger (hooks/lint-on-edit.sh)              │
│   - No business logic.                                                │
│   - Knows: host payload shape, env knobs, host response shape.        │
│   - Does not know: file types, linters, containers.                   │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ make lint FILE=…
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 2 — Routing (Makefile + scripts/lint-route.sh)                  │
│   - Owns the routing table (extension → sub-target).                  │
│   - Owns the "ignored" list and the "excluded paths" list.            │
│   - Owns the policy-gap (64) and wiring-missing (65) exit codes.      │
│   - Does not know: which linter runs (delegated to sub-targets).      │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ make lint-<ext> FILE=…
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 3 — Per-language enforcement (lint-ts, lint-md, …)              │
│   - Owns Docker invocation, linter binary, exit-code translation.     │
│   - Detects missing wiring → exit 65.                                 │
│   - Runs linter → exit 0 (pass) / 1 (violations).                     │
└──────────────────────────────────────────────────────────────────────┘
```

The benefit is that each layer is independently testable:

- Layer 1 with a stubbed `make` binary on `PATH`.
- Layer 2 with a stubbed `lint-<ext>` set in a test Makefile fixture.
- Layer 3 with the real container, but called directly (`make lint-ts FILE=…`) outside the hook.

---

## Technology Stack

| Component               | Technology                          | Rationale                                                                                                  |
| ----------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Hook script             | Bash 3.2-compatible                 | Already the project's convention (cf. `enforce-tools.sh`); zero extra runtime dep.                         |
| JSON extraction         | Pure Bash string walking            | Same trick as `enforce-tools.sh`; avoids forcing `jq` on minimal hosts.                                    |
| Router                  | Bash dispatcher invoked by Make     | Make's recipe quoting is fragile with paths containing spaces; a 30-line Bash dispatcher is cleaner.       |
| Per-language linters    | Whatever the host project uses      | The skill ships templates for Biome, markdownlint, yamllint, shellcheck, eslint, ruff — none mandatory.    |
| Container runtime       | `docker compose`                    | Same as `makefile-conventions`; reproducible per service.                                                  |
| Hook test runner        | Bats via Docker                     | Mature shell-script test framework; runs in CI without host install.                                       |
| Static analysis         | `shellcheck` via Docker             | `koalaman/shellcheck-alpine:stable` image; matches `NFR-003`.                                              |

---

## Project Structure

```text
.
├── hooks/
│   ├── enforce-tools.sh                    # existing
│   └── lint-on-edit.sh                     # NEW — the canonical hook body
├── scripts/
│   └── lint-route.sh                       # NEW — dispatcher invoked by `make lint`
├── Makefile                                # MUTATED — adds `lint`, `lint-md`, `lint-yaml`, `lint-json`, `lint-sh` for dogfood
├── skills/
│   ├── makefile-conventions/
│   │   └── SKILL.md                        # MUTATED — cross-link to new skill, new short section "See also: lint-router"
│   └── makefile-lint-router/               # NEW
│       ├── SKILL.md
│       └── examples/
│           ├── Makefile.ts-monorepo.example
│           ├── Makefile.python-uv.example
│           ├── Makefile.vue-nest.example
│           └── lint-route.sh.example
├── rules/
│   └── 04-tools-and-configurations/
│       └── 4-lint-on-edit.mdc              # NEW — short rule: "if your project has Docker + Make, install the lint-on-edit hook"
├── .claude/
│   └── settings.json                       # MUTATED or CREATED — registers PostToolUse hook (dogfood)
├── .cursor/
│   └── hooks.json                          # CREATED — registers the post-edit hook (dogfood); existing enforce-tools.sh stays untouched
├── asset-registry.yml                      # MUTATED — three new entries (hook, skill, rule), per spec 013 classification
├── tests/
│   └── hooks/
│       ├── lint_on_edit.bats               # NEW — unit tests for hook script
│       ├── lint_route.bats                 # NEW — unit tests for dispatcher
│       └── fixtures/                       # symlinks or copies of `specs/014-…/contracts/fixtures/`
└── specs/
    └── 014-lint-on-edit-hook/
        ├── prompt.md
        ├── spec.md
        ├── plan.md                          # this file
        ├── research.md
        ├── data-model.md
        ├── quickstart.md
        ├── tasks.md
        ├── stats.md
        └── contracts/
            ├── README.md
            ├── makefile-interface.md         # canonical contract: `make lint`, exit codes, env vars
            ├── hook-interface.md             # canonical contract: stdin shape, stdout shape, exit codes
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

---

## Implementation Strategy

### Phase 1 — Contracts and fixtures (red)

1. Author `contracts/hook-interface.md` and `contracts/makefile-interface.md` — the frozen contracts from `data-model.md` distilled to a one-page interface doc each.
2. Author every JSON / text fixture under `contracts/fixtures/` (see `data-model.md` §8). These are the "tests" that will turn green at the end.
3. Author `tests/hooks/lint_on_edit.bats` and `tests/hooks/lint_route.bats` skeletons (each test points at a fixture and asserts on the hook's stdout + exit code). Tests **must fail** at this point (hook does not exist).

### Phase 2 — Hook script (`hooks/lint-on-edit.sh`)

Targets: FR-001 to FR-009; NFR-003 to NFR-005.

1. Boilerplate identical to `enforce-tools.sh` (`set -uo pipefail`, debug logger, `read_stdin_all`).
2. `extract_json_string(payload, key)` lifted from `enforce-tools.sh::extract_command_field`, parametrised.
3. Host detection per `research.md` §5 (env first, payload sniff fallback).
4. Candidate-key resolution per `data-model.md` §2.2.
5. Outside-repo / deleted-file / excluded-path / `LINT_ON_EDIT=0` short-circuits — all silent allow.
6. Resolve repo root (`git rev-parse --show-toplevel` if available, else walk up looking for `Makefile`).
7. Compute relative path.
8. Run `make -C "$ROOT" lint FILE="$REL"` under `timeout "$LINT_TIMEOUT"` (POSIX `timeout` via `timeout` Docker image if not present? — decision: require `timeout(1)` from coreutils, fall back to pure-bash `( cmd & ; sleep N ; kill PID )` pattern if absent; documented in NFR-005 macOS Bash 3.2 compatibility).
9. Translate exit code per `data-model.md` §6:
   - `0` → silent allow.
   - Otherwise → format `[lint-on-edit] file=… ext=… target=… code=…\n\n<output>`, then either `exit 2` (Claude) or emit JSON envelope + `exit 0` (Cursor).
10. `shellcheck --severity=warning` clean.

### Phase 3 — Dispatcher (`scripts/lint-route.sh`)

Targets: FR-010 to FR-014; FR-016.

1. Declare `LINT_ROUTES`, `LINT_IGNORED`, `LINT_EXCLUDED_PATHS` arrays (cf. `data-model.md` §4).
2. Argument: a single file path (relative to the Makefile dir).
3. Path-prefix check → silent exit 0 if under an excluded directory.
4. Extension lookup:
   - In `LINT_IGNORED` → silent exit 0.
   - In `LINT_ROUTES` → `exec make lint-<target> FILE="$1"`.
   - Otherwise → print policy-gap message to stderr, exit 64.
5. `shellcheck --severity=warning` clean.

### Phase 4 — Makefile additions (root `Makefile`)

Targets: FR-010, FR-015, FR-025; dogfood SC-009.

1. Add `-include .env` and `export` if not present.
2. Declare the new section:

   ```make
   .PHONY: lint lint-md lint-yaml lint-json lint-sh

   lint: ## Lint a single file (FILE=path/to/file)
   	@./scripts/lint-route.sh "$(FILE)"

   lint-md:
   	@docker run --rm -v $$(pwd):/work -w /work davidanson/markdownlint-cli2:latest "$(FILE)"

   lint-yaml:
   	@docker run --rm -v $$(pwd):/work -w /work cytopia/yamllint:latest -s "$(FILE)"

   lint-json:
   	@docker run --rm -v $$(pwd):/work -w /work ghcr.io/jqlang/jq:latest 'empty' "$(FILE)" >/dev/null

   lint-sh:
   	@docker run --rm -v $$(pwd):/work -w /work koalaman/shellcheck-alpine:stable shellcheck --severity=warning "$(FILE)"
   ```

3. Document each target with the `## …` comment for `make help`.

### Phase 5 — Skill `makefile-lint-router`

Targets: FR-021, SC-008.

1. Author `skills/makefile-lint-router/SKILL.md` with:
   - Trigger phrases (frontmatter `description:` summarising "use when wiring lint-on-edit hook").
   - Section 1: The three-layer separation diagram (lifted from this plan).
   - Section 2: Routing table convention (with the `LINT_ROUTES`/`LINT_IGNORED`/`LINT_EXCLUDED_PATHS` template).
   - Section 3: Per-language sub-target templates (TS via Biome, JS via Biome, MD via markdownlint-cli2, YAML via yamllint, JSON via jq, SH via shellcheck, PY via ruff, GO via `go vet`).
   - Section 4: The "wiring missing" failure mode (exit 65 contract, with a worked example showing what happens when `npm run lint` is missing).
   - Section 5: Anti-patterns table (silent skip on missing linter ❌; per-extension Makefile flags ❌; etc.).
   - Section 6: Cross-link to `makefile-conventions`.
2. Author `skills/makefile-lint-router/examples/*` with three full Makefile examples and one full `lint-route.sh` example.

### Phase 6 — Rule `4-lint-on-edit.mdc`

Targets: FR-022, FR-023.

Short rule under `rules/04-tools-and-configurations/4-lint-on-edit.mdc`:

- States: "If your project has Docker and a Makefile, install the lint-on-edit hook from this repo."
- Lists the three layers (hook script, dispatcher, sub-targets).
- Lists when **not** to install (no Docker, no Make, exceptional projects).

Kept short on purpose (≤ 80 lines) — the long-form lives in the skill.

### Phase 7 — Host integrations (.claude, .cursor)

Targets: FR-017 to FR-020.

#### Claude

Add or extend `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/hooks/lint-on-edit.sh",
            "async": false,
            "timeout": 120,
            "env": { "LINT_HOOK_HOST": "claude" }
          }
        ]
      }
    ]
  }
}
```

If `${CLAUDE_PLUGIN_ROOT}` is preferred for plugin-distributed installs, the `quickstart.md` documents both forms.

#### Cursor

Add `.cursor/hooks.json` (or the equivalent file Cursor's docs specify at install time — `plan.md` v1 pins this name; if Cursor uses a different one, the migration is a `mv`):

```json
{
  "hooks": [
    {
      "event": "afterFileEdit",
      "command": "${workspaceFolder}/hooks/lint-on-edit.sh",
      "env": { "LINT_HOOK_HOST": "cursor" },
      "timeout": 120
    }
  ]
}
```

(Exact key names — `event` vs `trigger` vs `type` — are pinned at implementation time from Cursor's docs. The existing `enforce-tools.sh` does not have a sibling config in `.cursor/`; it is wired via the user-level Cursor settings instead, per local convention. This spec proposes a **project-level** Cursor hook config because lint policy is project-scoped, not user-scoped.)

#### Coverage-gap documentation

A short note in `quickstart.md` and in the Claude `settings.json` (`"comment"` field if Claude tolerates one, else inline doc above) explains:

> `PostToolUse` `Edit|Write` does NOT cover files written by the agent via `Bash`. For full coverage, also install a pre-commit Git hook running `make lint FILE=…` over `git diff --name-only`. That is a future spec.

### Phase 8 — Registry entries (per spec 013)

Targets: FR-022, FR-023, SC-010.

Add to `asset-registry.yml`:

```yaml
- path: hooks/lint-on-edit.sh
  type: hook
  category: tools-and-configurations
  bundles: [common]
  tags: [docker, lint, makefile, claude, cursor]
  description: Post-edit hook that routes file edits to a Dockerised linter via `make lint`.

- path: skills/makefile-lint-router/SKILL.md
  type: skill
  category: tools-and-configurations
  bundles: [common]
  tags: [docker, lint, makefile, hooks]
  description: How to write the lint routing Makefile that powers the lint-on-edit hook.

- path: rules/04-tools-and-configurations/4-lint-on-edit.mdc
  type: rule
  category: tools-and-configurations
  bundles: [common]
  tags: [docker, lint, hooks]
  description: Install the lint-on-edit hook in any project with Docker + Make.
```

Run the ajv-cli validation per spec 013's `quickstart.md` to confirm SC-010.

### Phase 9 — Tests turn green

Run the Bats suite from Phase 1. Tests MUST pass:

- Claude `Edit` payload + passing TS lint → silent.
- Claude `Edit` payload + failing TS lint → exit 2, stdout contains diagnostic.
- Cursor payload + failing MD lint → exit 0, JSON envelope, `agentMessage` contains diagnostic.
- Payload outside repo → silent.
- Unknown extension → exit 2 (Claude) or `deny`+message (Cursor), body contains "policy gap" phrase.
- Routed extension but sub-target missing → same shape, body contains "wire up" phrase.
- `LINT_ON_EDIT=0` → silent regardless of payload.

### Phase 10 — Dogfood + bench

1. Trigger an edit on `specs/014-lint-on-edit-hook/spec.md` from Claude → confirm `make lint FILE=specs/…/spec.md` runs and the hook is wired.
2. Run the latency benchmark (50 iterations on `spec.md`) → record P95 in `bench.md`.
3. Confirm SC-005 (P95 ≤ 5 s warm).

---

## Dependencies

External (Docker images, pulled at install / first run):

- `koalaman/shellcheck-alpine:stable` — shellcheck for the dogfood `lint-sh`.
- `davidanson/markdownlint-cli2:latest` — markdownlint for `lint-md`.
- `cytopia/yamllint:latest` — yamllint for `lint-yaml`.
- `ghcr.io/jqlang/jq:latest` — JSON syntactic check for `lint-json`.
- `bats/bats:latest` — Bats test runner.
- Per-project linter images (Biome, ESLint, Ruff, etc.) — project-defined, not shipped here.

Internal:

- Spec 013 (registry classification) MUST be merged before this spec lands so the new entries validate against the new schema.
- `skills/makefile-conventions/SKILL.md` — depended on for Docker-first conventions; cross-linked.
- `hooks/enforce-tools.sh` — referenced for pure-Bash JSON parsing pattern.

---

## Risks and Mitigations

| Risk                                                            | Mitigation                                                                                                             |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Cursor renames the post-edit event between spec and install     | Pin event name as a single constant in `.cursor/hooks.json`; doc the rename procedure in `quickstart.md` (one-line edit). |
| Claude `PostToolUse` semantics change (e.g. matcher syntax)     | Same: matcher value is one constant. Document in `quickstart.md`.                                                       |
| Linter latency tanks the edit loop                              | `LINT_ON_EDIT=0` escape hatch; warm-container guidance in the skill; `LINT_TIMEOUT` knob.                              |
| macOS Bash 3.2 incompatibility (associative arrays in dispatcher) | Dispatcher uses a `case` statement, not `declare -A`. Tested on `bash --version` `3.2.x` in CI.                       |
| Hook causes infinite loop (agent edits in response, hook fires, …) | Hook is purely read-only; never edits files. Loop impossible by design.                                              |
| `make` walks up the wrong directory (multi-Makefile monorepo)   | Hook resolves the Makefile via `git rev-parse --show-toplevel`; documented limitation otherwise.                       |
| Permissions error on `lint-on-edit.sh`                          | `install.sh` chmods +x; checklist item in `quickstart.md`.                                                              |
| User wants async (long lints)                                   | Single flag in `.claude/settings.json` (`async: true`); script behaviour unchanged.                                    |

---

## Out of Scope (re-stated)

- Pre-commit Git hook (future spec).
- `Bash`-driven write coverage (`FileChanged`).
- A formatter-on-save (not a lint-on-edit feature).
- A standalone linter binary.
- CI-side enforcement on PR diff (future spec).
- Internationalising agent messages.
- A dashboard / aggregation UI.

---

## Open Decisions (resolved here, not in spec)

| Decision                                | Choice                                                                          | Rationale                                                |
| --------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Extend `makefile-conventions` or fork?  | **Fork** new skill `makefile-lint-router`.                                       | Cleaner tags / discoverability (per `research.md` §7.2). |
| Sync vs async on Claude                 | **Sync** with 120 s timeout.                                                     | Headline value is in-turn feedback (per `research.md` §1.3). |
| Routing table location                  | `scripts/lint-route.sh` (single source).                                         | Bash quoting > Make quoting for paths with spaces (per `research.md` §6.3). |
| Cursor config location                  | `.cursor/hooks.json` at project root.                                            | Lint policy is project-scoped, not user-scoped.          |
| Exit codes `64`/`65`                    | Custom (modeled on `sysexits.h`).                                                | Lets the hook distinguish "found violations" from "config bug" without parsing message. |
| `jq` dependency                         | **Forbidden**.                                                                    | Match existing `enforce-tools.sh` discipline; minimal install footprint. |
| Bats vs custom test runner              | **Bats**.                                                                         | Mature, Docker-runnable, fits the project's Docker-first model. |
| Registry bundle                         | `bundles: [common]` for all three new entries.                                   | The hook is part of the minimum starter set this repo distributes. |
