---
name: makefile-lint-router
description: >-
  Install the lint-on-edit template in a consumer repo: a Bash hook that calls
  `make lint FILE=…` after every agent edit, and a Makefile recipe that routes
  each file glob to the right Dockerised linter. Distributed as a TEMPLATE PAIR
  — copy both, adapt the Makefile recipe to the project's file types and
  workspaces, register the hook in `.claude/settings.json` / `.cursor/hooks.json`.
---

# Makefile Lint Router — Template Pair

This skill ships a **template pair** that adds automatic lint-on-edit to any
project with Docker and GNU Make:

```text
┌────────────────────────────┐         ┌───────────────────────────────────┐
│ hooks/lint-on-edit.sh      │ ──────▶ │ Makefile `lint:` recipe (router)  │
│ (drop-in, no edits needed) │  make   │ (you adapt to your file types)    │
└────────────────────────────┘  lint   └───────────────────────────────────┘
        ▲                                       │
        │ stdin (agent payload)                 │ exec docker … linter
        │                                       ▼
   .claude/settings.json  ─┐         ┌─ stdout/stderr/exit ─┐
   .cursor/hooks.json     ─┴── register hook ───────────────┴── back to agent
```

The hook is **agent-side**: it knows how to read Claude/Cursor payloads and
how to talk back to the model. The Makefile recipe is **project-side**: it
owns the routing table — which glob runs which linter, in which container,
with which path prefix stripped.

The hook script is generic and copies as-is. **The Makefile recipe is the
file you adapt to your project.**

---

## 1. Files in this bundle

| File                                          | Role                              | Adapt?            |
| --------------------------------------------- | --------------------------------- | ----------------- |
| `hooks/lint-on-edit.sh` (repo root)           | The hook itself.                  | **No** — drop-in. |
| `templates/Makefile.minimal.example`          | Starter `lint:` recipe.           | **Yes** — fork.   |
| `templates/claude-settings.json`              | Claude Code hook registration.    | Path only.        |
| `templates/cursor-hooks.json`                 | Cursor hook registration.         | Path only.        |
| `examples/Makefile.ts-monorepo.example`       | Full example, TS monorepo.        | Reference.        |
| `examples/Makefile.python-uv.example`         | Full example, Python + uv.        | Reference.        |
| `examples/Makefile.vue-nest.example`          | Full example, Vue + NestJS.       | Reference.        |

---

## 2. Install in a consumer repo (5 steps)

```sh
# 1. Copy the hook (generic, no edits)
mkdir -p hooks
cp <this-repo>/hooks/lint-on-edit.sh hooks/
chmod +x hooks/lint-on-edit.sh

# 2. Copy the Makefile recipe starter, then adapt to your file types
cp <this-repo>/skills/makefile-lint-router/templates/Makefile.minimal.example .
# → merge its `lint:` target into your existing Makefile (or use it as a base)

# 3. Register the hook for Claude
mkdir -p .claude
cp <this-repo>/skills/makefile-lint-router/templates/claude-settings.json \
   .claude/settings.json

# 4. Register the hook for Cursor
mkdir -p .cursor
cp <this-repo>/skills/makefile-lint-router/templates/cursor-hooks.json \
   .cursor/hooks.json

# 5. Smoke-test
make lint FILE=README.md   # expect exit 0 (or markdownlint violations on exit 1)
```

After step 2 you **must** review the `lint:` recipe and add `case` branches
for the file types and workspaces specific to your project (see §4).

---

## 3. The contract — what `make lint` must do

The hook calls exactly one command:

```sh
make lint FILE=<repo-relative-path>
```

The recipe MUST honour this contract:

| Input                            | Expected behaviour                                              |
| -------------------------------- | --------------------------------------------------------------- |
| `FILE` empty / unset             | Print usage to stderr, exit `64`.                               |
| Path in excluded dir (`node_modules/`, `dist/`, …) | Exit `0` silently.                            |
| Path with ignored extension (`.png`, `.lock`, …)   | Exit `0` silently.                            |
| Path matches a routed glob       | `exec` the Dockerised linter; propagate its exit code.          |
| Path matches nothing             | Print "no case matches" to stderr, exit `64` (policy gap).      |

### Exit-code contract

| Code  | Set by                | Meaning                                                              |
| ----- | --------------------- | -------------------------------------------------------------------- |
| `0`   | excluded/ignored arm  | Silent allow.                                                        |
| `0`   | linter (in container) | Lint passed.                                                         |
| `1`   | linter (in container) | Lint ran AND found violations. **Hook surfaces this to the agent.**  |
| `64`  | recipe (catch-all)    | Policy gap — declare a new branch.                                   |
| `64`  | recipe (usage guard)  | Empty `FILE`.                                                        |
| `65`  | recipe (your choice)  | Wiring missing — a branch matched but its tool is not installed.     |

GNU Make wraps any non-zero recipe exit to status `2` and prints
`make: *** [Makefile:N: lint] Error <code>`. The hook recovers `<code>` from
that line. Do not try to suppress make's wrapper.

---

## 4. Anatomy of the recipe (what to adapt)

```make
.PHONY: lint

lint: ## Lint a single file (FILE=path/to/file)
	@F='$(FILE)'; \
	case "$$F" in \
	  '')                                          # ① usage guard \
	    printf 'lint: FILE=... is required\n' >&2; exit 64 ;; \
	  \
	  node_modules/*|*/node_modules/*|\
	  .git/*|*/.git/*|dist/*|*/dist/*)             # ② excluded paths \
	    exit 0 ;; \
	  \
	  *.png|*.lock|*.env|*.svg)                    # ③ ignored extensions \
	    exit 0 ;; \
	  \
	  apps/frontend/*)                             # ④ workspace branch \
	    exec docker compose exec -T frontend \
	      npm run lint -- "$${F#apps/frontend/}" ;; \
	  \
	  *.md|*.mdc)                                  # ⑤ generic extension branch \
	    exec docker run --rm -v "$$(pwd):/work" -w /work \
	      davidanson/markdownlint-cli2:latest "$$F" ;; \
	  \
	  *)                                           # ⑥ catch-all (policy gap) \
	    printf 'lint router: no case matches "%s".\n' "$$F" >&2; \
	    printf 'Add a branch to the `lint:` recipe.\n' >&2; \
	    exit 64 ;; \
	esac
```

**Branch ordering matters** — `case` is first-match-wins. Keep this order:

1. Empty-`FILE` guard.
2. Excluded paths — **must precede** extension branches so `node_modules/foo.md`
   exits silently rather than running markdownlint.
3. Ignored extensions — explicit silent allow-list.
4. Workspace branches — **must precede** generic extension branches so a `.ts`
   under `apps/frontend/` goes to the frontend container, not to a host-wide
   TypeScript linter.
5. Generic extension branches.
6. Catch-all `*)` — exit `64`, never `0`. A silent catch-all means new file
   types bypass lint forever.

### Workspace-aware branches (monorepo)

```make
	  apps/frontend/*) \
	    exec docker compose exec -T frontend \
	      npm run lint -- "$${F#apps/frontend/}" ;; \
	  apps/api/*) \
	    exec docker compose exec -T api \
	      ruff check "$${F#apps/api/}" ;; \
```

`$${F#apps/frontend/}` is POSIX parameter expansion — strip the shortest
matching prefix. The double `$$` escapes `$` for Make.

### Wiring-missing (exit 65)

```make
	  apps/api/*) \
	    docker compose exec -T api sh -lc \
	      'command -v ruff >/dev/null || { \
	         printf "lint: ruff not installed; add it to pyproject.toml\n" >&2; \
	         exit 65; \
	       }; \
	       ruff check "$${F#apps/api/}"' ;; \
```

The agent reads the body of the error and can fix the dependency.

---

## 5. Hook contract — what the script gives you

`hooks/lint-on-edit.sh` is generic. You do **not** edit it.

| Env knob              | Default      | Purpose                                                |
| --------------------- | ------------ | ------------------------------------------------------ |
| `LINT_ON_EDIT=0`      | `1`          | Kill-switch — disable the hook without removing config |
| `LINT_TIMEOUT=120`    | `120` (sec)  | Hard timeout on the `make lint` call                   |
| `LINT_HOOK_HOST`      | sniffed      | Force `claude` or `cursor` response shape              |
| `LINT_DEBUG=1`        | `0`          | Log to `/tmp/lint-on-edit.log` + stderr                |
| `LINT_VERBOSE=1`      | `0`          | Forward `LINT_VERBOSE` to `make` (consumed by recipes) |

Behaviour:

- **Pass (exit 0, no output)** → hook stays silent. Agent sees nothing.
- **Violations (exit 1)** → hook surfaces stderr+stdout to the agent
  (Claude: `exit 2` plain text; Cursor: `exit 0` JSON `agentMessage`).
- **Policy gap (exit 64)** → hook tells the agent to declare a new branch in
  the Makefile.
- **Wiring missing (exit 65)** → hook tells the agent which tool to install.
- **Timeout (exit 124)** → hook reports the timeout and the elapsed seconds.
- **No Makefile in ancestors** → hook exits 0 silently (project doesn't
  participate).

---

## 6. Anti-patterns

| Anti-pattern                                                | Why it fails                                                          |
| ----------------------------------------------------------- | --------------------------------------------------------------------- |
| External `lint.conf` / dispatcher shell script              | Adds a hop. The recipe IS the table. One file to read.                |
| Per-extension sub-targets (`lint-md:`, `lint-ts:` …)        | Duplicates routing across N targets. Tightly coupled when you add an extension. |
| Silent `exit 0` when a tool is missing                      | Agent thinks lint passed; violations accumulate.                      |
| Workspace branch placed AFTER the generic `*.ts` branch     | Wrong linter runs — workspace-specific config bypassed.               |
| Host-installed linter (`biome check $(FILE)` without docker) | Breaks reproducibility; linter version drifts between developers.    |
| Recipe `docker …` without `exec`                            | Extra wrapper PID. Use `exec docker …`.                               |
| Forgetting `$${F#prefix/}` in a workspace branch            | Linter sees `apps/frontend/src/foo.ts` but config expects `src/…`.    |
| Catch-all `*)` that exits `0` instead of `64`               | Policy gap is hidden — new file types silently bypass lint forever.   |
| Editing `hooks/lint-on-edit.sh` to add project logic        | Wrong layer. Project logic belongs in the Makefile recipe.            |

---

## 7. Adding a new file type — checklist

1. Open the project's root `Makefile`.
2. In the `lint:` recipe, **insert a branch** in the right position (see §4 ordering).
3. Pick the shape:
   - **Workspace branch?** → `<prefix>/*) exec docker compose exec -T <svc> <cmd> "$${F#<prefix>/}" ;; \`
   - **Generic branch?** → `*.<ext>) exec docker run --rm -v "$$(pwd):/work" -w /work <image> <cmd> "$$F" ;; \`
   - **Silent allow?** → add the glob to the excluded-paths or ignored-extensions branch.
4. `make lint FILE=<sample>` — confirm exit code.
5. Commit. Nothing else to touch.

---

## 8. See also

- [makefile-conventions](../makefile-conventions/SKILL.md) — Docker-first Makefile baseline this skill extends.
- `hooks/lint-on-edit.sh` — the hook (template, drop-in).
- `templates/` — the three files you copy into a consumer repo.
- `examples/` — full Makefile templates for TS monorepo, Python/uv, Vue + Nest.
- `rules/04-tools-and-configurations/4-lint-on-edit.mdc` — repo rule: install the hook in any Docker + Make project.
- `specs/014-lint-on-edit-hook/contracts/hook-interface.md` — frozen hook ↔ host interface.
- `specs/014-lint-on-edit-hook/contracts/makefile-interface.md` — frozen hook ↔ Makefile interface.

---

## Implementation Status

**Fully Implemented** — `hooks/lint-on-edit.sh` ships in this repo and is
covered by the Bats suite under `tests/hooks/` (run `make test-hooks`).
Templates under `templates/` and `examples/` are ready to copy into consumer
repos. This repo does **not** install the pair on itself (it distributes the
template; it is not a consumer).
