# Quickstart — Install the lint-on-edit hook in your project

**Audience**: developers adopting the `lint-on-edit` policy in a fresh or existing project.
**Time**: ~ 5 minutes for the minimal setup, ~ 20 minutes including per-language linter wiring.
**Prerequisites**: Docker (running), GNU Make, Bash 3.2+, Git.

> This is the dogfood / consumer guide. For implementation details, read [`plan.md`](./plan.md) and [`research.md`](./research.md).

---

## 1. Copy the three asset files

From this repo into your target project:

```bash
# In your target project root:
TARGET=/path/to/your/project
SRC=/path/to/gh-agentic-workflow

mkdir -p "$TARGET/hooks" "$TARGET/scripts"

cp "$SRC/hooks/lint-on-edit.sh"   "$TARGET/hooks/"
cp "$SRC/scripts/lint-route.sh"    "$TARGET/scripts/"
chmod +x "$TARGET/hooks/lint-on-edit.sh" "$TARGET/scripts/lint-route.sh"
```

Or run the repo-level installer from the source repo:

```bash
# From gh-agentic-workflow root — installs all assets including the lint-on-edit bundle
./install.sh
```

The installer copies `hooks/`, `scripts/`, `skills/`, and `rules/` to your Cursor and agent directories. For project-level wiring (`.claude/settings.json` and `.cursor/hooks.json`), follow the manual steps in §4 and §5 below.

---

## 2. Add the `lint` target to your Makefile

If your `Makefile` is empty, start from the `skills/makefile-conventions` template. Append:

```make
# ──── Lint-on-Edit (spec 014) ────────────────────────────────
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

Add per-language targets (`lint-ts`, `lint-js`, `lint-py`, …) following the templates in `skills/makefile-lint-router/examples/`.

### Quick smoke test

```bash
echo '{"foo": }' > broken.json   # malformed JSON
make lint FILE=broken.json
# Expected: jq error, exit 1
rm broken.json
```

---

## 3. Wire Claude Code

Edit (or create) `.claude/settings.json`:

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

> If you ship this as a Claude plugin, swap `${CLAUDE_PROJECT_DIR}` for `${CLAUDE_PLUGIN_ROOT}`.

### Known coverage gap

`PostToolUse` `Edit|Write` covers `Edit` and `Write` tools — NOT files written via `Bash` (`echo … > file.ts`). Complement with a Git pre-commit hook for full coverage; see `plan.md` Out of Scope.

---

## 4. Wire Cursor

Create `.cursor/hooks.json` at the project root:

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

> Verify the event name against the current Cursor hooks docs at install time. If renamed, change only the `event` field — the script and the Makefile do not move.

---

## 5. Verify end-to-end

### 5.1 Happy path

```bash
# In your target project:
cat > _smoke.md <<'EOF'
# Hello

This is a clean markdown file.
EOF

bash hooks/lint-on-edit.sh <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$(pwd)/_smoke.md"}}
EOF
echo "exit code: $?"   # expected: 0
rm _smoke.md
```

### 5.2 Failure path (violation)

```bash
cat > _smoke.md <<'EOF'
# heading without trailing newline
EOF

LINT_HOOK_HOST=claude bash hooks/lint-on-edit.sh <<EOF
{"tool_name":"Edit","tool_input":{"file_path":"$(pwd)/_smoke.md"}}
EOF
echo "exit code: $?"   # expected: 2; stdout contains the markdownlint diagnostic
rm _smoke.md
```

### 5.3 Policy gap (unknown extension)

```bash
touch _smoke.foo

LINT_HOOK_HOST=claude bash hooks/lint-on-edit.sh <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$(pwd)/_smoke.foo"}}
EOF
echo "exit code: $?"   # expected: 2; stdout asks to declare .foo in the router
rm _smoke.foo
```

### 5.4 Ignored extension (silent)

```bash
touch _smoke.lock

bash hooks/lint-on-edit.sh <<EOF
{"tool_name":"Write","tool_input":{"file_path":"$(pwd)/_smoke.lock"}}
EOF
echo "exit code: $?"   # expected: 0; stdout empty
rm _smoke.lock
```

### 5.5 Disabled

```bash
LINT_ON_EDIT=0 bash hooks/lint-on-edit.sh <<EOF
{"tool_name":"Edit","tool_input":{"file_path":"$(pwd)/anything.ts"}}
EOF
echo "exit code: $?"   # expected: 0; stdout empty (no Docker call)
```

---

## 6. Static analysis

```bash
docker run --rm -v "$(pwd):/mnt" koalaman/shellcheck-alpine:stable \
  shellcheck --severity=warning /mnt/hooks/lint-on-edit.sh /mnt/scripts/lint-route.sh
# Expected: zero findings.
```

---

## 7. Bats tests (optional but recommended)

```bash
docker run --rm -v "$(pwd):/code" -w /code bats/bats:latest tests/hooks/
# Expected: all green.
```

---

## 8. Latency benchmark

Reference benchmark used to verify SC-005:

```bash
# 50 iterations on a clean markdown file. Adjust FILE for your stack.
for i in $(seq 1 50); do
  /usr/bin/time -p bash hooks/lint-on-edit.sh <<EOF 2>>bench.log >/dev/null
{"tool_name":"Edit","tool_input":{"file_path":"$(pwd)/specs/014-lint-on-edit-hook/spec.md"}}
EOF
done

awk '/real/ {print $2}' bench.log | sort -n | awk 'BEGIN{c=0} {a[c++]=$1} END{print "p50="a[int(c*0.5)]; print "p95="a[int(c*0.95)]}'
```

P95 ≤ 5 s satisfies `NFR-001` / `SC-005` on a warm container.

---

## 9. Disable the hook temporarily

Three escape hatches, from broadest to narrowest:

| Knob              | Effect                                            |
| ----------------- | ------------------------------------------------- |
| `LINT_ON_EDIT=0`  | Hook exits silently on every invocation.          |
| Remove the hook from `.claude/settings.json` / `.cursor/hooks.json` | Editor no longer triggers the hook.    |
| Add the extension to `LINT_IGNORED` in `scripts/lint-route.sh` | Silent for that file type only. |

---

## 10. Troubleshooting

| Symptom                                                | Likely cause                                            | Fix                                                                |
| ------------------------------------------------------ | ------------------------------------------------------- | ------------------------------------------------------------------ |
| Every edit prints `policy gap`                          | An extension you use is in neither list.                | Add the extension to `LINT_ROUTES` (with a `lint-<ext>` target) or to `LINT_IGNORED`. |
| Hook prints `wire up`                                   | Routed extension but the sub-target's underlying linter is missing in the container. | Wire the linter (e.g. add a `lint` script to `package.json`, install the binary in the Dockerfile). |
| `docker: command not found`                            | Docker not in PATH.                                     | Install Docker / start Docker Desktop.                              |
| Hook hangs                                              | Cold container start.                                   | Raise `LINT_TIMEOUT` or run `make up` ahead of time to keep containers warm. |
| Hook does not fire at all                               | Editor's hook config is wrong.                          | Open the editor's hook config UI; verify the path to `lint-on-edit.sh` resolves. |
| Hook fires on `node_modules/`                          | `LINT_EXCLUDED_PATHS` is missing the directory.         | Add the directory prefix (with trailing `/`) to `LINT_EXCLUDED_PATHS`. |
