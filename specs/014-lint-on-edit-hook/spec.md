# Feature Specification: Lint-on-Edit Hook (Claude + Cursor) routed by Makefile

**Feature Branch**: `014-lint-on-edit-hook`
**Created**: 2026-05-22
**Status**: Draft
**Input**: Add an editor-agent hook for both Claude Code and Cursor that triggers a deterministic linter every time the agent edits or creates a file. The hook does not know about file types; it forwards the file path to a single, generic `make lint FILE=…` target. The `Makefile` plays the role of a router: it dispatches to the correct linter inside the correct container. If the file type *should* be linted but no linter is wired up, the hook MUST block and report the gap to the LLM so the agent fixes the missing configuration instead of silently skipping the check.

---

## Context

The project ships reusable AI assets (rules, skills, commands, hooks, agents) that other repositories install via `install.sh` / `install.ps1`. One asset that is conspicuously missing is a **deterministic feedback loop on every file edit**: today, when the agent writes a TypeScript or YAML file, nothing checks it until a human runs `npm run lint` or `make test`. The agent therefore happily produces code that fails the project's lint rules, and the human has to either notice and re-prompt or fix it after the fact.

Two pieces already exist in the repo and shape the design:

1. `hooks/enforce-tools.sh` — a Cursor `beforeShellExecution` hook that demonstrates the JSON-stdin → permission/agentMessage contract used by Cursor hooks. It is **purely deterministic**: parses JSON without `jq`, returns `{permission, continue, agentMessage}`.
2. `skills/makefile-conventions/SKILL.md` — documents the project's Docker-first Makefile conventions (`-include .env`, `COMPOSE` / `EXEC_BACKEND` patterns, mandatory `help`, `up`, `down`, `test`).

What is missing:

- **No `lint` target convention** in `makefile-conventions` — the skill covers `test` but says nothing about per-file linting from a hook.
- **No `PostToolUse` / `afterFileEdit` hook** wired to call that target.
- **No agreed contract** for what "no linter configured for this extension" means and how the hook signals it to the agent.

The goal of this feature is to fill all three gaps with **distributable assets** (hook script + Makefile pattern + skill update + Claude/Cursor configuration snippets) plus a **dogfood install** on this repo so the convention is self-validating.

---

## User Scenarios & Testing (mandatory)

### User Story 1 — Agent edits a file and gets immediate, deterministic feedback (Priority: P1)

As an AI agent (Claude Code or Cursor) running inside a project that installed this asset, when I edit or create a file whose extension is declared lintable, I want the project's linter for that file type to run automatically and tell me whether the file passes, so I can fix violations in the same turn instead of being told later by a human reviewer.

**Why this priority**: This is the headline value. Without this loop, every other policy in the repo (clean code rule, semantic-jsdoc rule, naming rule) is enforced only "in spirit". A deterministic lint-on-edit makes those rules executable feedback rather than read-only norms.

**Independent Test**: In a fresh sandbox project that installed the asset, the agent edits `src/foo.ts` with a lint violation (e.g. an unused variable). The hook MUST run, the linter MUST execute, and the agent MUST receive an `agentMessage` containing the linter's diagnostic. Running the same edit on a clean file MUST produce no message.

**Acceptance Scenarios**:

1. **Given** a project with `make lint FILE=…` wired to a working TypeScript linter inside a container, **When** the agent saves a TS file containing a lint error, **Then** the hook intercepts the result and surfaces the linter's textual diagnostic back to the agent (block the post-edit success signal so the agent loops).
2. **Given** the same project, **When** the agent saves a TS file that passes lint, **Then** the hook is silent (no `agentMessage` injected, no extra UI noise).
3. **Given** an edit to a file whose extension is **explicitly** declared as "no linter needed" (e.g. `.png`, `.lock`), **When** the hook fires, **Then** it returns silently without invoking the Makefile (early-exit on extension allow-list).

---

### User Story 2 — Missing linter wiring blocks instead of silently passing (Priority: P1)

As a tech lead reviewing the AI's output, I want the hook to **refuse to silently pass** when a lintable extension has no concrete linter wired up in the Makefile router, so the agent does not get false positives ("everything OK") on files no one is actually checking.

**Why this priority**: This is the trap the user explicitly called out. If `.ts` is declared lintable but the container has no `npm run lint` script, today's naive approach would either crash (and confuse the agent) or skip (and lie). The whole point of the design is to make "linter not wired up" a **visible** error that the agent can fix by editing the Makefile / Dockerfile / `package.json`.

**Independent Test**: Take a project that declares `.ts` as lintable in the router but whose `lint-ts` target points at a missing script. Trigger an edit on `src/foo.ts`. Verify that the hook blocks the agent with a message such as: `"lint router declares .ts as lintable but target 'lint-ts' failed: command 'npm run lint' not found in service 'app'. Wire it up before continuing."`

**Acceptance Scenarios**:

1. **Given** the Makefile's routing table maps `.ts` → `lint-ts`, **When** `lint-ts` exits non-zero because the underlying linter command is missing in the container, **Then** the hook surfaces the **stderr + stdout** of `make lint` verbatim and emits an `agentMessage` that names (a) the file, (b) the extension, (c) the target it tried, and (d) the underlying error.
2. **Given** an edited file whose extension is **not** in the routing table **and** not in the extension allow-list, **When** the hook fires, **Then** it MUST emit a "policy gap" `agentMessage` that lists the extension and asks the agent to either add a router entry or extend the allow-list — never silent.
3. **Given** the agent fixes the missing wiring (adds `lint:ts` script in the container, or adds the extension to the allow-list), **When** it edits the same file again, **Then** the hook either runs the now-working linter or stays silent — no manual intervention required to "reset" the hook.

---

### User Story 3 — The hook runs identically under Claude Code and under Cursor (Priority: P1)

As a maintainer who works in both editors, I want the same hook script and the same Makefile to power both Claude Code's `PostToolUse` and Cursor's `afterFileEdit` (or its equivalent post-edit event), so the lint policy is enforced consistently regardless of which agent host the developer uses.

**Why this priority**: Editor parity is a hard constraint of this repo (we already ship `.claude/` and `.cursor/` configs side-by-side). A hook that works on Claude but not on Cursor would create a silent escape hatch.

**Independent Test**: Install the asset bundle in a sandbox project. Trigger the same edit (a TS file with a lint error) from a Claude Code session and from a Cursor session. Both sessions MUST receive a non-empty `agentMessage`/equivalent containing the linter diagnostic; both MUST receive zero noise on a clean edit.

**Acceptance Scenarios**:

1. **Given** the asset is installed, **When** I inspect the generated configuration files, **Then** there is a Claude Code config registering the hook for the write/edit tools and a Cursor config registering the hook for the post-edit event, both pointing at the **same** underlying shell script and the **same** Makefile target.
2. **Given** the Claude side uses tool-name matching (`Edit|Write`) and Cursor uses an event-name matching, **When** the shell script reads stdin, **Then** the script handles both JSON payload shapes (different field names for the file path) and degrades to a clear `agentMessage` if neither shape is parsable.
3. **Given** a Claude `PostToolUse` event tied to a `Bash` write (e.g. `echo … > file.ts`), **When** the hook fires, **Then** it documents this as a known limitation and either (a) participates if Cursor provides a file-change event or (b) clearly marks the gap in the agent message so the user understands shell-driven writes are not covered.

---

### User Story 4 — A reusable skill teaches how to write the routing Makefile (Priority: P2)

As a maintainer onboarding a new project to this policy, I want a dedicated skill that explains, with copy-pasteable templates, how to (a) declare lintable extensions, (b) wire each extension to a Dockerised linter, (c) signal "not yet wired" instead of "OK", and (d) keep the table maintainable when the stack grows.

**Why this priority**: Without this skill, every project will reinvent the routing convention. With it, the policy becomes a five-minute paste-and-adapt exercise.

**Independent Test**: A maintainer with no prior context reads the new skill, then writes a Makefile for a fresh Vue/Nest monorepo. They get a working `make lint FILE=…` target that routes `.ts`, `.vue`, `.scss`, `.yml`, `.md` to the correct container without asking the agent for help.

**Acceptance Scenarios**:

1. **Given** the new or extended skill, **When** I follow the documented template, **Then** the resulting `Makefile` has: (a) a routing table (extension → sub-target), (b) an explicit "extensions ignored on purpose" list, (c) a "linter not wired" failure mode that exits non-zero with a structured message, (d) Docker-first execution per `makefile-conventions`.
2. **Given** the skill is registered in `asset-registry.yml` (per the new classification rules from spec 013), **When** I query the registry, **Then** the skill appears in the right `category` and carries the right `tags` (e.g. `tags: [makefile, docker, lint, hooks]`).

---

### User Story 5 — The hook degrades gracefully when `docker`/`make` are missing (Priority: P2)

As a developer running the agent on a machine where Docker is temporarily down or where `make` is not installed, I want the hook to fail with a clear actionable message instead of hanging or producing a cryptic JSON-parse error.

**Why this priority**: Hooks block the agent loop. A silent failure here would break the developer's flow worse than no hook at all.

**Independent Test**: Disable Docker daemon, then trigger an edit. The hook MUST return within a documented timeout with `agentMessage` = "docker daemon unreachable; cannot run linter; check `docker info`" (or equivalent), and the agent MUST be able to continue (the hook does not crash the session).

**Acceptance Scenarios**:

1. **Given** `docker` is not in `PATH` on the host, **When** the hook fires, **Then** it returns a structured message naming the missing dependency.
2. **Given** `make` is not in `PATH`, **When** the hook fires, **Then** it returns the same shape of message naming `make`.
3. **Given** the linter target hangs (e.g. container start failure), **When** the hook waits past its configured timeout, **Then** it kills the child process and returns a "timeout: <duration>s; consider raising `LINT_TIMEOUT` or fixing the container" message.

---

## Edge Cases

- **File path is outside the project root** (e.g. agent edits `~/.zshrc`). The hook MUST detect this and silently no-op (no policy gap message); linting host config is out of scope.
- **File path contains spaces or unicode**. The hook MUST quote correctly when invoking `make lint FILE="…"`; nothing should break for `apps/Some App/src/index.ts`.
- **File was just deleted** (the edit removed it). The hook MUST detect `file does not exist` and silently no-op — linting a deleted file is meaningless.
- **Binary file falsely classified as a source extension**. Not in scope: the Makefile router can call its linter, and if the linter explodes, that explosion is the agent's signal.
- **Concurrent edits** (agent rewrites the file twice in quick succession). The hook MUST be safe to run concurrently against the same path; either both runs complete independently, or the second supersedes the first via a per-path lock (decision left to the implementation, documented in `plan.md`). No corrupted state.
- **Very large files** (e.g. 10 MB generated SQL dump). The Makefile router decides whether to skip; the hook does not impose a size limit but MUST honour a documented `MAX_FILE_BYTES` env override.
- **Hook runs in CI** (e.g. a sandbox agent runs in a pipeline). The hook MUST detect a CI environment via an env var (e.g. `CI=true`) and behave identically — or, if the project chose to disable it in CI, that decision must be expressible via a single env flag (`LINT_ON_EDIT=0`).
- **Multiple monorepo packages**. The Makefile router is the only place that knows which container handles `apps/foo/*.ts` vs `packages/bar/*.ts`. The hook stays oblivious.
- **Hook script invoked by hand** (no JSON stdin). The script MUST detect this and emit a usage message instead of crashing.
- **`PostToolUse` matcher coverage**: a file written via `Bash` (`echo … > file.ts`) does NOT trigger Claude's `PostToolUse` Edit|Write event. This is documented as a known gap (FR-018), not silently glossed over.

---

## Requirements (mandatory)

### Functional Requirements — Hook script

- **FR-001**: A single shell script (POSIX-safe Bash) named `lint-on-edit.sh` MUST exist under `hooks/` at the repo root and serve as the canonical hook body for **both** Claude Code and Cursor.
- **FR-002**: The script MUST read the hook payload from stdin and accept two known JSON shapes: Claude `PostToolUse` (`{"tool_input": {"file_path": "..."}}`) and Cursor's post-edit event (field name from the event docs; the script MUST handle the actual key emitted by the Cursor event used).
- **FR-003**: The script MUST resolve the file path to a path **relative to the repo root** (where the `Makefile` lives) before calling `make`. Absolute paths inside the repo MUST be converted; paths outside the repo MUST trigger a silent no-op (per Edge Cases).
- **FR-004**: The script MUST invoke `make lint FILE="<rel-path>"` from the repo root (or the closest ancestor containing a `Makefile`). It MUST capture both stdout and stderr.
- **FR-005**: If `make lint` exits zero, the script MUST exit zero with no output (silent success).
- **FR-006**: If `make lint` exits non-zero, the script MUST emit a structured JSON response to stdout that:
  - Uses the **Claude exit-code 2 / `agentMessage` convention** on Claude (so Claude routes the message back into the model context).
  - Uses the Cursor `{"permission": "deny", "continue": true, "agentMessage": "..."}` convention on Cursor.
  - Detection between the two MUST be deterministic, based either on an env variable provided by the host (`CLAUDE_HOOK=1` / `CURSOR_HOOK=1`) or on a sniff of the input payload shape; the chosen mechanism MUST be documented and testable.
- **FR-007**: The script MUST honour two env knobs: `LINT_ON_EDIT` (`0`/`1`, default `1`) and `LINT_TIMEOUT` (seconds, default documented in `plan.md`). When `LINT_ON_EDIT=0`, the script exits zero immediately. When `LINT_TIMEOUT` is hit, the script kills the child `make` invocation and returns the timeout message defined in User Story 5.
- **FR-008**: The script MUST NOT depend on `jq` (per the existing `enforce-tools.sh` convention — pure Bash JSON extraction). Adding `jq` would block installs on minimal hosts.
- **FR-009**: The script MUST be idempotent and side-effect-free aside from invoking `make`: no temp files outside `/tmp`, no global state, no logging unless `LINT_DEBUG=1`.

### Functional Requirements — Makefile router

- **FR-010**: The `Makefile` at repo root MUST expose a single target `lint` that accepts a `FILE` argument (`make lint FILE=path/to/file.ts`).
- **FR-011**: The target MUST internally dispatch by file extension to a per-extension sub-target (e.g. `lint-ts`, `lint-md`, `lint-yml`). Dispatch logic MUST live in the `Makefile` (or a shell helper invoked from the `Makefile`); the hook MUST remain dispatch-agnostic.
- **FR-012**: The `Makefile` MUST declare two explicit lists at the top of the lint section:
  1. **Routed extensions** — extensions with a sub-target.
  2. **Ignored extensions** — extensions explicitly out of scope (e.g. `.png`, `.lock`, `.svg`, binary assets).
- **FR-013**: If the incoming `FILE` has an extension that is in neither list, `make lint` MUST exit non-zero with a documented message such as `"lint router: extension '.xyz' is neither routed nor ignored; declare it in the Makefile"`. This makes the policy gap visible to the agent (per User Story 2).
- **FR-014**: If the extension is routed but the sub-target's underlying command fails (e.g. missing `npm run lint` script in the container), `make lint` MUST propagate a non-zero exit code AND emit a message that names the failed sub-target and the underlying error (per User Story 2 acceptance scenario 1).
- **FR-015**: Every sub-target MUST run inside a Docker container per the `makefile-conventions` skill — no host-installed linter assumption.
- **FR-016**: The Makefile MUST be re-entrant: invoking `make lint FILE=…` twice in quick succession MUST not corrupt cached state.

### Functional Requirements — Host integrations (Claude + Cursor)

- **FR-017**: A Claude Code hook configuration file (`.claude/settings.json` or per-plugin `hooks.json`) MUST be shipped (or documented) that registers `lint-on-edit.sh` on `PostToolUse` with `matcher: "Edit|Write"` and a documented `timeout` (e.g. 300s). It MUST also set `async: true` if the Claude docs at install time allow it, OR be sync with a clearly documented latency budget — the choice MUST be explicit in `plan.md`, not implicit.
- **FR-018**: The Claude config MUST document the known coverage gap that `PostToolUse` `Edit|Write` does NOT cover files written by `Bash` (e.g. `echo … > file.ts`). The doc MUST point to `FileChanged` as a possible complement and explain why it is or is not used.
- **FR-019**: A Cursor hook configuration MUST be shipped (or documented) that registers `lint-on-edit.sh` on the equivalent post-edit event. If multiple Cursor events are candidates, the chosen event MUST be justified in `research.md`.
- **FR-020**: Both configurations MUST point at the **same** `hooks/lint-on-edit.sh` and use the **same** `make lint FILE=…` contract. There MUST NOT be two divergent scripts.

### Functional Requirements — Skill, registry, install

- **FR-021**: The existing skill `skills/makefile-conventions/SKILL.md` MUST be extended (or a sibling skill MUST be created — decision in `plan.md`) to document the lint-router pattern: routing table, ignored-extensions list, "wiring missing" failure mode, per-language sub-target templates (TS, JS, YAML, Markdown, Shell, JSON, Python, Go), and integration with the hook.
- **FR-022**: The new/extended skill MUST be registered in `asset-registry.yml` with the correct `category`, `bundles`, and `tags` per spec 013's classification rules. If `bundles: [common]` applies, it MUST be declared so the lint-on-edit policy ships with the common starter set.
- **FR-023**: The hook script and the Claude/Cursor config snippets MUST be registered in `asset-registry.yml` as `type: hook` and `type: rule` (or `type: command`, decided in `plan.md`) entries with appropriate paths and tags.
- **FR-024**: The repo's own `install.sh` / `install.ps1` MUST be able to install the hook into a target project without manual editing — either by copying the files and rewriting the `.claude/`/`.cursor/` configs idempotently, or by emitting a clear set of instructions if idempotent rewriting is out of scope (decision in `plan.md`).
- **FR-025**: The repo MUST dogfood the asset: this repo's own `Makefile` MUST expose `make lint FILE=…` covering at minimum `.md`, `.mdc`, `.yml`, `.yaml`, `.json`, `.sh` (the file types this repo actually produces). The hook MUST be wired in this repo's `.claude/` and `.cursor/` configs.

### Non-Functional Requirements

- **NFR-001**: A clean-lint invocation (file passes lint) MUST complete in under **5 seconds** P95 on a warm container, measured on a TS file ≤ 500 LOC, so the editing loop stays interactive.
- **NFR-002**: A first-call invocation (cold container) MUST complete in under **30 seconds** or the hook MUST emit a "warming up" `agentMessage` and return — never silently hang past `LINT_TIMEOUT`.
- **NFR-003**: The hook script MUST be ≤ **300 lines of Bash**, must avoid `jq`/`yq`/`python` dependencies, and must pass `shellcheck --severity=warning` cleanly.
- **NFR-004**: The hook MUST not produce stdout when silent (no decorative banners), so it does not pollute the host's transcript.
- **NFR-005**: The hook MUST behave identically on macOS (Bash 3.2) and on Linux (Bash 4+/5). No `bash`-4-only features unless guarded.
- **NFR-006**: The Makefile additions MUST conform to the `makefile-conventions` skill: `.PHONY`, `-include .env`, Docker-first, no host-installed tools.

---

## Key Entities (if data involved)

- **HookInvocation**: `{ host: "claude" | "cursor", payload: object, file_path: string, project_root: string, env: { LINT_ON_EDIT, LINT_TIMEOUT, LINT_DEBUG } }` — the runtime context of one hook execution.
- **LintRequest**: `{ relative_path: string, extension: string }` — what the hook hands to the Makefile.
- **RouteTable**: `{ routed: { ".ts": "lint-ts", ".md": "lint-md", ... }, ignored: [".png", ".lock", ...] }` — declared in the Makefile, single source of truth for "what is lintable".
- **LintResult**: `{ exit_code: integer, stdout: string, stderr: string, duration_ms: integer, target_invoked: string | null }` — what the Makefile returns to the hook.
- **HostResponse**: depending on host, either Claude's `{exit_code: 2, ... } + stdout JSON` or Cursor's `{permission: "deny"|"allow", continue: true, agentMessage: string}` — what the hook returns to the editor.

---

## Success Criteria (mandatory, measurable, technology-agnostic)

- **SC-001**: After installing the asset bundle in a fresh sandbox project, an agent edit on a TS file with a deliberately seeded lint error MUST cause the agent's next turn to receive a textual diagnostic that mentions the rule name and line number. Measurement: scripted end-to-end test producing a transcript fixture; the diagnostic MUST be greppable in the transcript.
- **SC-002**: An agent edit on a file with a routed extension but **no wired linter** MUST cause the agent's next turn to receive a "linter not configured for `<ext>`" message naming the failing sub-target. Measurement: same scripted test with a broken `lint-ts` target; transcript MUST contain the exact phrase.
- **SC-003**: An agent edit on a file whose extension is in the `ignored` list MUST produce **zero** lines of output in the transcript from the hook. Measurement: scripted test on a `.png` edit; transcript diff MUST be byte-identical between hook-installed and hook-disabled runs.
- **SC-004**: An agent edit on a file whose extension is in **neither** list MUST produce a "policy gap" message that explicitly invites the agent to add an entry to the router. Measurement: scripted test on a `.xyz` edit; transcript MUST contain the policy-gap phrase.
- **SC-005**: P95 latency of a passing TS lint on a warm container MUST be ≤ 5 s on the reference machine; P95 for a failing lint MUST be ≤ 6 s. Measurement: 50-iteration loop captured in `quickstart.md`'s benchmark section, results stored in `specs/014-lint-on-edit-hook/bench.md`.
- **SC-006**: The hook script MUST pass `shellcheck --severity=warning` with **zero** findings. Measurement: CI / Docker one-liner documented in `quickstart.md`.
- **SC-007**: The same hook script, the same Makefile, and the same routing table MUST handle a Claude `PostToolUse` payload and a Cursor `afterFileEdit`-equivalent payload, both producing the same `agentMessage` content for the same edit. Measurement: side-by-side fixture under `contracts/fixtures/` (one Claude payload, one Cursor payload) → identical `agentMessage` substring.
- **SC-008**: The skill update MUST add at least one "wiring missing" worked example AND at least three per-language sub-target templates (TS, MD, YAML), all Docker-first. Measurement: skill diff vs current `skills/makefile-conventions/SKILL.md` shows the new sections.
- **SC-009**: After dogfood installation on this repo, running `make lint FILE=specs/014-lint-on-edit-hook/spec.md` MUST exit zero or fail with a real markdown-lint diagnostic. Measurement: actual run in `quickstart.md` benchmark step.
- **SC-010**: The `asset-registry.yml` entries for the hook, the configs, and the (updated or new) skill MUST validate against `asset-registry.schema.json` post-spec-013. Measurement: ajv-cli Dockerised run per spec 013's `quickstart.md`.
- **SC-011**: The hook script + the Claude/Cursor config snippets + the Makefile additions MUST be installable in a fresh project in under **5 minutes** by a developer following only `quickstart.md`. Measurement: timed walkthrough captured in `quickstart.md`.

---

## Assumptions

- The host project has Docker installed and a working `make`. The hook degrades gracefully without them (per User Story 5) but the feature target audience is projects already on the `makefile-conventions` baseline.
- Claude Code's hook system continues to expose `PostToolUse` with a `matcher: "Edit|Write"` semantics as documented at <https://code.claude.com/docs/en/hooks>. If the spec evolves (e.g. `MultiEdit` becomes standard), the matcher value is the **only** thing to change — the script and the Makefile contract are immune.
- Cursor's hook system exposes a post-file-edit event whose payload contains the file path. The exact event name and field path are pinned in `research.md` based on the documentation at spec-time; if Cursor renames the event, only the configuration shipped under `.cursor/` changes.
- The repo's existing convention "JSON parsing in Bash without `jq`" (visible in `hooks/enforce-tools.sh`) is intentionally preserved; we will not introduce `jq` as a runtime dependency.
- Spec 013 ships before this one: the `asset-registry.yml` already uses the new `category` / `bundles` / cleaned `tags` axes. Registry edits for spec 014 will follow that taxonomy.
- The decision between **extending** `skills/makefile-conventions` and **forking** a new `skills/makefile-lint-router` is left to `plan.md`; the spec mandates that the documentation exists, not how it is named.
- A separate spec will later wire the same hook into a CI step (run on changed files in a PR). Out of scope here.

---

## Out of Scope

- A standalone linter binary. The hook **invokes** existing linters via `make`; it does not implement linting logic.
- A formatter-on-save mechanism (e.g. running Prettier and rewriting the file). The hook **reads** and **reports**, never mutates files.
- A web UI / dashboard summarising lint failures across a session.
- Integrating with `FileChanged` to cover `Bash`-driven writes (documented as a known gap in FR-018; future enhancement).
- Linting on **read** events (pre-edit). The contract is post-edit only.
- Pre-commit / Git hook integration. The hook lives in the **agent host**, not in Git.
- A `MultiEdit`-specific matcher (Claude doc at spec-time does not list it).
- Internationalising hook messages. All messages are English (per repo doctrine).
- Linting files inside `node_modules`, `dist`, `build`, `.git`, `vendor` — the hook MUST early-exit on these paths (this is a hard rule of the implementation, but the **list** of excluded directories is configuration, documented in `plan.md`).
