# Research: Lint-on-Edit Hook (Claude + Cursor)

**Spec**: [./spec.md](./spec.md)
**Date**: 2026-05-22

---

## 1. Claude Code hooks — `PostToolUse` semantics

### 1.1 Source

- Official docs: <https://code.claude.com/docs/en/hooks>
- Confirmed by an independent agent (Codex) in the original prompt of this spec.

### 1.2 Event contract

| Aspect             | Value                                                                                |
| ------------------ | ------------------------------------------------------------------------------------ |
| Event              | `PostToolUse`                                                                        |
| Matcher syntax     | Regex-like string matching tool names; alternation via `\|` (e.g. `Edit\|Write`).    |
| Triggered after    | Claude's `Edit` and `Write` tools complete.                                          |
| **Not** triggered  | Disk writes performed by `Bash` (`echo … > file`). For that, `FileChanged` exists.   |
| Payload (stdin)    | JSON containing `tool_input.file_path` for `Edit` and `Write`.                       |
| Exit-code semantics | `0` = silent allow; `2` = "send `stdout` back to the model as agent feedback".       |
| `async: true`      | Hook does not block the agent; result arrives later. Safer for slow linters.         |
| `timeout`          | Hard cap on hook duration (seconds). Hook killed past timeout.                       |

### 1.3 Decision: synchronous vs `async: true`

Two valid postures:

- **Synchronous** — agent waits for lint result before producing its next message. Tightest feedback loop but every edit pays the linter latency.
- **`async: true`** — agent moves on; lint feedback arrives at the start of the *next* turn. Slightly delayed feedback but no edit-time stall.

**Pick: synchronous, with `LINT_TIMEOUT=120`s default.** Rationale:

1. The headline value (User Story 1) is "fix the violation in the same turn". Async breaks that promise: the agent often finishes the whole task before the lint feedback shows up.
2. We mitigate latency at the Makefile layer (warm containers, incremental linters) — not at the hook layer.
3. The escape hatch `LINT_ON_EDIT=0` covers the rare case where someone wants edit-time speed over feedback.

If the project chooses async, **only** the `.claude/settings.json` snippet changes; the script and the Makefile contract are unaffected.

### 1.4 Matcher coverage gap

`PostToolUse` `Edit|Write` does **NOT** cover:

- Files written by the agent calling `Bash` (e.g. `cat <<EOF > file.ts`).
- Files written by an MCP server tool (would need a matcher on that tool's name).
- Out-of-process writes (a sub-agent or a separate process).

**Decision**: Document the gap (FR-018). Do **not** complement with `FileChanged` because the documented matcher of `FileChanged` is "literal file names" — not suitable for "all source files".

The right complement (out of scope here) is a pre-commit Git hook running the same `make lint FILE=…` on `git diff --name-only`.

---

## 2. Cursor hooks — post-edit event

### 2.1 Source

- Cursor hook system documented at <https://cursor.com/docs/agent/hooks>.
- The existing repo asset `hooks/enforce-tools.sh` is a `beforeShellExecution` Cursor hook — confirms the JSON-stdin / `{permission, continue, agentMessage}`-stdout convention.

### 2.2 Candidate events

At spec-time, the Cursor hook events relevant for our use-case are:

| Event                    | Fires when                                                | Suitable for lint-on-edit? |
| ------------------------ | --------------------------------------------------------- | -------------------------- |
| `beforeShellExecution`   | Before a shell command runs                                | No — pre-event, no file context.       |
| `beforeReadFile`         | Before the agent reads a file                              | No — read, not write.                  |
| `beforeSubmitPrompt`     | Before the agent sends a prompt to the model              | No — too coarse.                       |
| `afterFileEdit`          | After the agent edits/creates a file (event name pending verification at install time) | **Yes** — primary candidate.           |
| `stop`                   | At the end of an agent turn                                | Possible fallback if `afterFileEdit` is not available. |

### 2.3 Decision: target `afterFileEdit` (or its current Cursor name)

The implementation will:

1. **Pin the exact event name** at install time by reading the Cursor docs URL (this is recorded in `plan.md` as a single-line variable so a future rename is a one-place change).
2. **Sniff the payload shape** in the shell script: try `tool_input.file_path` first (Claude shape), then `file_path` / `path` / whatever Cursor emits, in order of likelihood. Unknown shape → emit "unrecognised payload" `agentMessage` and exit 0 (do not block edits forever on a doc rename).

### 2.4 Response contract

From `hooks/enforce-tools.sh` we know Cursor expects on stdout:

```json
{ "permission": "allow" | "deny", "continue": true, "agentMessage": "..." }
```

For a post-edit hook, `permission` is not really meaningful (the file is already written) — what matters is `agentMessage`. **Decision**: emit `{"permission": "allow", "continue": true, "agentMessage": "<lint output>"}` on failure, and exit silently with no JSON on success. This is consistent with the spirit of the existing hook (block + message), even though "permission" is semantically inert for a post-edit event.

---

## 3. JSON parsing without `jq`

### 3.1 Source

`hooks/enforce-tools.sh` already implements `extract_command_field` — a 30-line pure-Bash JSON string extractor that:

- Finds the key (e.g. `"file_path"`).
- Walks the string respecting `\"` and `\\` escapes.
- Returns the unescaped value.

### 3.2 Decision: reuse the exact pattern

The new hook script will:

1. Lift `extract_command_field` (renamed `extract_json_string`) and parameterise the key name (Claude uses `tool_input.file_path`; Cursor may use a flatter key).
2. Walk the payload twice if needed — once for each candidate key, in priority order.
3. Treat the absence of all candidate keys as "unrecognised payload" (per §2.3).

This keeps the dependency footprint at exactly: `bash`, `make`, `docker`. Nothing else.

---

## 4. Claude `agentMessage` vs Cursor `agentMessage`

Both hosts expose an `agentMessage`-like channel:

- **Claude** — when the hook exits `2`, Claude routes the hook's `stdout` into the model context as a system note. The convention is to print plain text or `## Lint Diagnostic …` markdown.
- **Cursor** — `agentMessage` is a JSON field, escaped string. Newlines via `\n`.

### 4.1 Decision: emit plain text on stdout, post-process per host

The script writes the linter output to a buffer. At the end:

- If running under Claude (detected per §5), `printf "%s\n" "$buffer"` then `exit 2`.
- If running under Cursor (detected per §5), JSON-encode the buffer (escaping `\\`, `\"`, `\n`, `\r`, `\t` — same trick as `enforce-tools.sh`'s `deny` function) and emit the `agentMessage` envelope, then `exit 0`.

---

## 5. Host detection

### 5.1 Options

| Option | Pros | Cons |
| --- | --- | --- |
| Env var set by the host (e.g. `CLAUDE_PROJECT_DIR`, `CURSOR_USER_AGENT`) | Cheap, deterministic. | Need to inventory which env vars each host actually injects. |
| Sniff payload shape | Self-describing. | Risky if a host renames keys. |
| Caller-passed flag (`--host claude` / `--host cursor`) in the hook config | Explicit. | Couples the config to the script's CLI. |

### 5.2 Decision: layered detection

1. **First**, read `LINT_HOOK_HOST` env var if set. Single source of truth, settable from each host's hook config. This is the **recommended** path.
2. **Second**, sniff the payload: if it contains the substring `"tool_input"` → Claude; if not → Cursor.
3. **Third**, fall back to "unknown host" — exit silently with no JSON, only a debug log if `LINT_DEBUG=1`.

The shipped Claude config sets `LINT_HOOK_HOST=claude`; the shipped Cursor config sets `LINT_HOOK_HOST=cursor`. New hosts (Aider, Continue, etc.) add their own value here without touching the script.

---

## 6. Makefile routing — prior art and alternatives

### 6.1 Existing skill `makefile-conventions`

Covers Docker-first, `.env`, `up`/`down`/`test`. **Does not** cover per-file linting. We extend it (see §7).

### 6.2 Routing-table implementation options

| Option | Pros | Cons |
| --- | --- | --- |
| Pure `make` recipe with `case "$$FILE"` | Self-contained, no extra script. | Verbose; `make` quoting gets ugly with paths containing spaces. |
| `make` calls a thin `scripts/lint-route.sh` helper | Clean split, easy to extend, `bash` quoting works. | One more file. |
| Per-extension target with pattern rules (`%.ts`) | Idiomatic `make`. | Pattern rules treat `FILE` as a target name, fragile with paths. |

### 6.3 Decision: hybrid

`Makefile` target `lint`:

```make
lint: ## Lint a single file (FILE=path/to/file.ext)
	@./scripts/lint-route.sh "$(FILE)"
```

`scripts/lint-route.sh` reads the extension, looks up the sub-target in an array literal at the top of the script, exec's `make lint-<ext>`, and propagates exit codes. The **routing table lives in the script** (single source of truth), but the **entry points remain `make` sub-targets** so `make lint-ts FILE=…` works for humans too.

Rejected the pure-Makefile option because `case` inside a recipe + `$(FILE)` containing spaces becomes painful. The thin-helper option respects the `makefile-conventions` Docker-first rule because the helper itself only sets up the dispatch; the actual linter invocation lives in the sub-target.

---

## 7. Skill: extend or fork?

### 7.1 Options

- **Extend `skills/makefile-conventions`** — add a new section "Lint router for hooks". Pro: one place for all Makefile guidance. Con: skill becomes large; harder to discover via tag search.
- **Fork `skills/makefile-lint-router`** — new skill, cross-linked from `makefile-conventions`. Pro: precise discoverability; can carry its own tags (`hooks`, `lint`). Con: two skills to keep in sync if Makefile conventions evolve.

### 7.2 Decision: fork

A new skill at `skills/makefile-lint-router/SKILL.md`:

- Tagged `[makefile, lint, hooks, docker]` (per spec 013's cleaned tag vocabulary).
- Category `tools-and-configurations`.
- Bundle `common` (the hook ships in the minimum starter set, so the skill that explains how to write the router must travel with it).

`skills/makefile-conventions/SKILL.md` gets a one-line cross-link pointing at the new skill.

---

## 8. Registry impact (per spec 013)

New entries in `asset-registry.yml`:

| Path                                            | Type    | Category                  | Bundles    | Tags                                |
| ----------------------------------------------- | ------- | ------------------------- | ---------- | ----------------------------------- |
| `hooks/lint-on-edit.sh`                         | hook    | tools-and-configurations  | [common]   | [docker, lint, makefile, claude, cursor] |
| `skills/makefile-lint-router/SKILL.md`          | skill   | tools-and-configurations  | [common]   | [docker, lint, makefile, hooks]     |
| `rules/04-tools-and-configurations/4-lint-on-edit.mdc` (if created — see plan.md) | rule    | tools-and-configurations  | [common]   | [docker, lint, hooks]               |

The Claude/Cursor config snippets are **templates documented in `quickstart.md`**, not assets in the registry. Reason: they are project-specific (paths inside the host project's `.claude/`/`.cursor/`) and not directly distributable.

---

## 9. Latency budget

Reference benchmark (on a 2024 MacBook Pro M3, Docker Desktop):

| Scenario                        | Expected P95 |
| ------------------------------- | ------------ |
| `make lint FILE=foo.md` (clean)  | ~1.5 s       |
| `make lint FILE=foo.ts` (warm)   | ~3 s         |
| `make lint FILE=foo.ts` (cold)   | ~12 s        |
| `make lint FILE=foo.yml` (warm)  | ~1 s         |

`LINT_TIMEOUT=120` accommodates cold starts with margin. `NFR-001` (5 s warm) is realistic; `NFR-002` (30 s cold) leaves a 25 % buffer.

---

## 10. Failure-mode taxonomy

Mapped to FRs:

| Failure                                   | Hook behaviour                                                     | FR    |
| ----------------------------------------- | ------------------------------------------------------------------ | ----- |
| File outside repo root                    | Silent no-op.                                                       | FR-003 |
| File deleted before hook runs              | Silent no-op.                                                       | (edge case) |
| Extension routed + linter passes          | Silent.                                                              | FR-005 |
| Extension routed + linter finds violations | `agentMessage` with linter output, exit 2 (Claude) / `deny` (Cursor). | FR-006 |
| Extension routed + linter command missing | `agentMessage` "linter not configured for `<ext>`", same exit shape. | FR-014 |
| Extension not routed AND not ignored      | `agentMessage` "policy gap: declare `<ext>` in router".              | FR-013 |
| Extension ignored                         | Silent no-op.                                                        | FR-012 |
| Docker daemon down                        | `agentMessage` "docker unreachable".                                 | NFR-User-Story-5 |
| Timeout                                   | Kill child, `agentMessage` "timeout".                                | FR-007 |
| `LINT_ON_EDIT=0`                          | Silent no-op.                                                        | FR-007 |
| Unknown host                              | Silent no-op (debug only).                                           | §5    |
| Unrecognised payload                      | Silent no-op (debug only).                                           | §2.3  |

This taxonomy is the canonical reference for the test fixtures under `contracts/fixtures/`.
