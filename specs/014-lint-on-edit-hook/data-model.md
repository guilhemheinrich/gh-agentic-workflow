# Data Model: Lint-on-Edit Hook

**Spec**: [./spec.md](./spec.md)
**Date**: 2026-05-22

The "data" here is not persisted state — it is the **runtime contracts** between (a) the agent host (Claude or Cursor), (b) the hook script, (c) the Makefile router, and (d) the per-language sub-targets. Pinning the shapes here is what lets every component be tested in isolation.

---

## 1. Boundary diagram

```text
┌──────────────┐    JSON stdin    ┌────────────────────┐    make lint     ┌────────────┐
│ Claude/Cursor│ ───────────────▶ │ hooks/             │ ───────────────▶ │ Makefile   │
│ agent host   │                  │ lint-on-edit.sh    │                  │ router     │
│              │ ◀─────────────── │                    │ ◀─────────────── │            │
└──────────────┘  JSON stdout +   └────────────────────┘  exit code +     └─────┬──────┘
                  exit code                              captured I/O           │
                                                                                ▼
                                                                  ┌──────────────────────┐
                                                                  │ make lint-<ext>      │
                                                                  │ (docker compose run) │
                                                                  └──────────────────────┘
```

Each arrow has a **frozen contract** below.

---

## 2. Boundary 1 — Agent host → Hook script (JSON over stdin)

### 2.1 Claude `PostToolUse` payload (canonical)

```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "/abs/path/to/repo/src/foo.ts",
    "...": "other tool-specific fields"
  },
  "tool_response": { "...": "..." },
  "session_id": "uuid",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/abs/path/to/repo"
}
```

The hook script extracts **only** `tool_input.file_path` from this shape. All other fields are ignored.

For `Write` events, the same `file_path` field carries the created file.

### 2.2 Cursor post-edit payload (canonical)

The exact event name and JSON keys are pinned in `plan.md` from the Cursor docs at install time. The script declares a **priority list of candidate JSON keys**:

```text
1. tool_input.file_path     ← Claude
2. file_path                ← Cursor (most likely)
3. path                     ← Cursor (alternate)
4. file                     ← Cursor (alternate)
```

The first key found wins. If none is found, the script logs and exits silently (cf. failure taxonomy in `research.md` §10).

### 2.3 Env vars set by the host

| Variable                | Set by         | Meaning                                                    |
| ----------------------- | -------------- | ---------------------------------------------------------- |
| `LINT_HOOK_HOST`        | Hook config    | `claude` \| `cursor` \| custom. Drives the response shape. |
| `CLAUDE_PROJECT_DIR`    | Claude         | Absolute path of the project root (when set).              |
| `CLAUDE_PLUGIN_ROOT`    | Claude plugin  | Path to plugin root (used to locate the hook).             |
| `CI`                    | CI runner      | If `true`, hook can be silenced by `LINT_ON_EDIT=0`.       |

The script reads `LINT_HOOK_HOST` first; absence → payload sniff per §2.2.

---

## 3. Boundary 2 — Hook script → Makefile

### 3.1 Invocation contract

```bash
make -C "$PROJECT_ROOT" lint FILE="$RELATIVE_PATH"
```

- `PROJECT_ROOT` is the closest ancestor of the edited file containing a `Makefile`. Discovered by walking up from `dirname "$FILE_PATH"`.
- `RELATIVE_PATH` is the file path **relative to `PROJECT_ROOT`** (e.g. `src/foo.ts`, never `/abs/path/src/foo.ts`).
- The hook captures stdout AND stderr into a single buffer (line-merged, stderr lines prefixed by `stderr: ` only if `LINT_DEBUG=1`).

### 3.2 Exit-code semantics from `make lint`

| Exit code | Meaning                                                                            | Hook behaviour              |
| --------- | ---------------------------------------------------------------------------------- | --------------------------- |
| `0`       | Lint passed.                                                                        | Silent allow.               |
| `1` (or 2)| Lint ran AND found violations.                                                      | `agentMessage` with output. |
| `64`      | Policy gap: extension in neither routed nor ignored list.                           | `agentMessage` "declare `<ext>`". |
| `65`      | Linter wiring missing (routed extension, sub-target failed at *invoke* stage).      | `agentMessage` "wire up `<ext>`". |
| `124`     | Hook script's own timeout (matches `timeout(1)`'s convention).                      | `agentMessage` "timeout".   |
| other     | Unexpected failure (Docker down, syntax error in Makefile, etc.).                   | `agentMessage` with output. |

Codes `64`/`65` are **chosen by the Makefile**, not by the hook. They give the hook a clean way to distinguish "lint diagnostic" from "configuration bug" without parsing the message body. They are documented in the skill (`makefile-lint-router`) so projects adopting the convention emit the same codes.

### 3.3 Environment forwarded to `make`

| Variable           | Default | Use                                                          |
| ------------------ | ------- | ------------------------------------------------------------ |
| `FILE`             | —       | The relative path. Required.                                 |
| `LINT_VERBOSE`     | `0`     | If `1`, sub-targets print extra context.                     |
| `LINT_FORMAT`      | `text`  | `text` \| `json`. Sub-targets may honour `json` for machine-readable output. v1 ships `text`. |

Nothing else leaks from the hook into the Makefile.

---

## 4. The routing table

The single source of truth lives in `scripts/lint-route.sh` (per `research.md` §6.3):

```bash
# Edit this table to add or remove extensions.
declare -A LINT_ROUTES=(
  [".ts"]="lint-ts"
  [".tsx"]="lint-ts"
  [".js"]="lint-js"
  [".jsx"]="lint-js"
  [".json"]="lint-json"
  [".yml"]="lint-yaml"
  [".yaml"]="lint-yaml"
  [".md"]="lint-md"
  [".mdc"]="lint-md"
  [".sh"]="lint-sh"
  [".bash"]="lint-sh"
  [".py"]="lint-py"
  [".go"]="lint-go"
  [".rs"]="lint-rs"
)

# Explicit "no linter on purpose" list — silent allow.
LINT_IGNORED=(
  ".png" ".jpg" ".jpeg" ".gif" ".webp" ".svg" ".ico"
  ".woff" ".woff2" ".ttf" ".eot"
  ".lock" ".lockb"
  ".pdf" ".zip" ".tar" ".tgz" ".gz"
  ".env" ".envrc"
  ".gitignore" ".dockerignore" ".npmignore"
)

# Directories whose contents are never linted (silent allow).
LINT_EXCLUDED_PATHS=(
  "node_modules/" "dist/" "build/" ".next/" ".nuxt/"
  ".git/" ".cache/" "coverage/" "vendor/" ".venv/"
)
```

**Contract**:

1. An extension MUST be in `LINT_ROUTES` OR in `LINT_IGNORED`. Otherwise the dispatcher exits `64` (policy gap).
2. `LINT_EXCLUDED_PATHS` is checked **before** the extension lookup: a `.ts` file under `node_modules/` is silently skipped.
3. Adding a routed extension WITHOUT adding the corresponding `lint-<ext>` target in the Makefile is a configuration bug; the dispatcher exits `65` when the sub-target is missing or its body errors at startup.

---

## 5. Sub-target contract (`lint-<ext>`)

Every per-language target follows the same shape:

```make
lint-ts: ## Lint a single TypeScript file (internal — called by `lint`)
	@if ! $(COMPOSE) ps app | grep -q ' Up '; then \
		printf "lint-ts: service 'app' not running. Start with 'make up'.\n" >&2; \
		exit 65; \
	fi
	@$(EXEC_APP) sh -lc 'command -v biome >/dev/null || { echo "lint-ts: biome not installed in container"; exit 65; }'
	@$(EXEC_APP) sh -lc 'biome check "$(FILE)"' || exit 1
```

Each target MUST:

- **Detect missing wiring** (linter binary absent, service down) and exit `65`. Never `0`.
- **Run the linter** and propagate its native exit code as `1` (violations found) or `0` (clean).
- **Print only the linter's output**; no decorative banner.
- **Run inside Docker** (no host-installed linter assumption).

Sub-targets are NOT required to be `.PHONY` because they are dispatched via the route script, but declaring them `.PHONY` is recommended for human invocation (`make lint-ts FILE=foo.ts`).

---

## 6. Boundary 3 — Hook script → Agent host (stdout + exit code)

### 6.1 Silent success

```text
exit 0
(no stdout)
```

Both hosts treat this as "no agent feedback".

### 6.2 Claude failure response

```text
stdout: <linter output, plain text, may include markdown>
exit 2
```

Claude's `PostToolUse` documentation specifies that exit code `2` routes stdout back to the model as agent feedback. The hook does NOT emit JSON in this case — plain text is the contract.

### 6.3 Cursor failure response

```text
stdout: {"permission":"allow","continue":true,"agentMessage":"<escaped linter output>"}
exit 0
```

Cursor expects a JSON envelope and a zero exit code; the `agentMessage` carries the linter output. The string MUST be escaped per the same trick as `enforce-tools.sh::deny` (`\\`, `\"`, `\n`, `\r`, `\t`).

### 6.4 Universal preamble in the message body

For both hosts, the body of the message MUST begin with a structured header so the agent can parse "what kind of failure" this is without reading the whole text:

```text
[lint-on-edit] file=<relative_path> ext=<ext> target=<lint-X|none> code=<exit_code>

<linter output>
```

This is a soft convention (not enforced by the host); it dramatically improves agent readability in transcripts.

---

## 7. Persistence — none

The hook is stateless. No cache, no lock file, no disk write apart from optional debug logs to `/tmp/lint-on-edit.log` when `LINT_DEBUG=1`.

Rationale: state introduces failure modes (stale cache, lock leakage) that outweigh the benefit at the 1-file-per-call granularity. The Makefile sub-targets MAY introduce per-target caches (e.g. Biome's cache directory) — those are scoped to the container, not to the hook.

---

## 8. Reference fixtures (under `contracts/fixtures/`)

| Fixture                                  | What it proves                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------- |
| `claude-edit-valid.json`                 | A canonical Claude `PostToolUse` payload for an `Edit` event.             |
| `claude-write-valid.json`                | Same for a `Write` event.                                                 |
| `cursor-afteredit-valid.json`            | A canonical Cursor post-edit payload (using the actual key name pinned in `plan.md`). |
| `payload-unknown-shape.json`             | An empty / unrecognised payload — script MUST silent no-op.               |
| `payload-outside-repo.json`              | A `file_path` that resolves outside `PROJECT_ROOT`.                       |
| `expected-claude-response-pass.txt`      | Expected stdout + exit code for a passing lint under Claude.              |
| `expected-claude-response-fail.txt`      | Expected stdout + exit code for a failing lint under Claude.              |
| `expected-cursor-response-pass.json`     | Expected stdout JSON + exit code for a passing lint under Cursor.         |
| `expected-cursor-response-fail.json`     | Expected stdout JSON + exit code for a failing lint under Cursor.         |
| `route-table-fixture.sh`                 | A standalone copy of the routing table used by the unit tests.            |

These are referenced from `contracts/README.md`.
