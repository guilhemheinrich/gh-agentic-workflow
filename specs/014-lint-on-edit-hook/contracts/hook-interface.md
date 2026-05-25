# Contract — Hook script ↔ Agent host

**Owner**: `hooks/lint-on-edit.sh`
**Consumers**: Claude Code (`PostToolUse` `Edit|Write`), Cursor (post-edit event).

---

## Input: JSON on stdin

The hook script reads **one** JSON object from stdin. Two payload shapes are supported:

### Shape A — Claude `PostToolUse`

```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "<absolute or repo-relative path>"
  },
  "...": "other fields ignored"
}
```

**Required key path**: `tool_input.file_path`.

### Shape B — Cursor post-edit event

```json
{
  "file_path": "<absolute or repo-relative path>",
  "...": "other fields ignored"
}
```

**Required key path**: one of `file_path`, `path`, `file` (first present wins, in this order).

### Resolution rules

1. The script tries the keys in this exact order, returning on first match:
   - `tool_input.file_path` (Claude)
   - `file_path`
   - `path`
   - `file`
2. If none is found → silent allow (exit `0`, no stdout). The hook MUST NOT block the agent on an unrecognised payload.

---

## Input: environment variables

| Variable           | Required | Default     | Effect                                                                       |
| ------------------ | -------- | ----------- | ---------------------------------------------------------------------------- |
| `LINT_HOOK_HOST`   | no       | (sniffed)   | `claude` \| `cursor` \| custom. Selects the response envelope.               |
| `LINT_ON_EDIT`     | no       | `1`         | `0` → silent allow regardless of payload.                                    |
| `LINT_TIMEOUT`     | no       | `120`       | Seconds. Hook kills `make` after this many seconds and emits a timeout msg. |
| `LINT_DEBUG`       | no       | `0`         | `1` → log every step to `/tmp/lint-on-edit.log` (and stderr).                |
| `LINT_VERBOSE`     | no       | `0`         | Forwarded to `make`. Sub-targets may print extra context.                    |
| `CI`               | no       | (unset)     | Informational; does not change behaviour unless `LINT_ON_EDIT=0` is set.    |

If `LINT_HOOK_HOST` is unset, the script sniffs:

1. Payload contains the substring `"tool_input"` → Claude.
2. Otherwise → Cursor.

---

## Output: stdout + exit code

Three branches:

### B1 — Silent allow

Triggered by:

- Empty / unrecognised payload.
- `LINT_ON_EDIT=0`.
- File outside the repo root.
- File no longer exists.
- File path matches an entry in `LINT_EXCLUDED_PATHS` (e.g. `node_modules/`).
- Extension in `LINT_IGNORED`.
- `make lint` exited `0`.

Output:

```text
(nothing on stdout)
exit code: 0
```

### B2 — Claude failure response

Triggered by any non-zero `make lint` exit code under `LINT_HOOK_HOST=claude`.

Output:

```text
[lint-on-edit] file=<rel_path> ext=<ext> target=<lint-X|none> code=<exit_code>

<verbatim make lint stdout+stderr>

exit code: 2
```

Claude's contract: exit code `2` routes stdout into the model context as agent feedback.

### B3 — Cursor failure response

Triggered by any non-zero `make lint` exit code under `LINT_HOOK_HOST=cursor`.

Output (single line of JSON, no trailing whitespace):

```json
{"permission":"allow","continue":true,"agentMessage":"[lint-on-edit] file=… ext=… target=… code=…\n\n<escaped output>"}
```

Cursor's contract: exit code `0` + JSON envelope on stdout. `permission` is `"allow"` because the edit already happened; we cannot retroactively deny it. The semantically active field is `agentMessage`.

The escaped output follows the same escape table as `hooks/enforce-tools.sh::deny`:

| Source byte | Escape   |
| ----------- | -------- |
| `\`         | `\\`     |
| `"`         | `\"`     |
| LF (0x0A)   | `\n`     |
| CR (0x0D)   | `\r`     |
| TAB (0x09)  | `\t`     |

---

## Exit-code contract

| Exit code | Source       | Meaning                                            | Host translation                                  |
| --------- | ------------ | -------------------------------------------------- | ------------------------------------------------- |
| `0`       | Hook         | Silent allow.                                       | No-op.                                            |
| `2`       | Hook (Claude) | Agent feedback follows on stdout.                  | Claude routes stdout to model.                    |
| `0`       | Hook (Cursor) | Agent feedback follows in stdout JSON envelope.    | Cursor routes `agentMessage` to model.            |
| —         | —            | Hook never exits with any code other than `0`/`2`. | (Hook never propagates `make`'s exit code raw.) |

The hook **NEVER** exits with the raw exit code of `make`. It translates everything per the table above. This means `64`/`65`/`124` from `make lint` end up as either exit `2` (Claude) or exit `0` (Cursor) with a `agentMessage` describing the underlying cause.

---

## Side effects

- The hook MUST NOT write to disk except `/tmp/lint-on-edit.log` when `LINT_DEBUG=1`.
- The hook MUST NOT modify the touched file. Ever. No auto-fix.
- The hook MUST NOT call any network resource directly (the linter inside the container is permitted to).

---

## Performance

- P95 latency (clean lint, warm container): ≤ 5 s. See `NFR-001`.
- P95 latency (cold container): ≤ 30 s. See `NFR-002`.
- Hook overhead (excluding `make lint`): ≤ 100 ms.

---

## Versioning

This contract is at **v1.0.0**. Breaking changes (new required env var, new output shape, removed key from input resolution) MUST bump the major. The version is **not** encoded inside the script — it lives in the spec ID (`014`) and in the comment header of the script.
