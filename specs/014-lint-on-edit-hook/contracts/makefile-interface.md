# Contract — Makefile router (`make lint`)

**Owner**: root `Makefile` (single `lint:` target).
**Consumer**: `hooks/lint-on-edit.sh`.

---

## Invocation

```bash
make -C "$PROJECT_ROOT" lint FILE="<repo-relative-path>"
```

- `PROJECT_ROOT` is the directory containing the `Makefile`.
- `FILE` is a path **relative to `PROJECT_ROOT`**, e.g. `apps/foo/src/index.ts`. Absolute paths inside the repo MUST be converted by the hook before this contract takes effect.

---

## Behaviour

The `lint` target is a **single recipe** whose body is the routing table. There is **no external dispatcher script** and there are **no per-extension sub-targets**. Every glob → linter mapping is declared inline as a `case` branch in the `lint:` recipe of the root `Makefile`.

The recipe MUST:

1. Reject empty `FILE` with a usage message + exit `64`.
2. Match `FILE` against an ordered list of `case` patterns covering, in order:
   1. **Excluded paths** (`node_modules/*`, `dist/*`, `.git/*`, `vendor/*`, …) → `exit 0` (silent).
   2. **Ignored extensions** (`*.png`, `*.lock`, `*.env`, …) → `exit 0` (silent).
   3. **Workspace-specific routes** (e.g. `apps/frontend/*` → `docker compose exec -T frontend …` with the `apps/frontend/` prefix stripped from the path passed to the container).
   4. **Generic extension routes** (`*.md`, `*.yml`, `*.json`, `*.sh`, …) → `exec docker run …` against the file.
   5. **Catch-all** → policy-gap message on stderr + exit `64`.
3. Use `exec docker …` (not just `docker …`) so the shell process is replaced — preserves child semantics and avoids an extra wrapper PID.
4. NEVER call host-installed linters. Every branch MUST go through Docker (per `makefile-conventions`).

When the project is a monorepo, a branch matching a workspace prefix MUST strip that prefix when handing the path to the in-container linter (POSIX shell `${F#apps/frontend/}` form).

---

## Exit-code contract

| Code  | Source                    | Meaning                                                                                       |
| ----- | ------------------------- | --------------------------------------------------------------------------------------------- |
| `0`   | Recipe (excluded/ignored) | Path matched an excluded-prefix or ignored-extension branch.                                  |
| `0`   | Linter inside docker      | Lint passed.                                                                                  |
| `1`   | Linter inside docker      | Lint ran AND found violations.                                                                |
| `64`  | Recipe                    | Policy gap: no branch matched. Edit the `lint:` recipe to declare the new glob.               |
| `64`  | Recipe                    | Usage error: empty `FILE`.                                                                    |
| `65`  | Recipe (project-defined)  | Wiring missing: a branch needed a tool that is not installed in its container. Convention.    |
| `124` | Hook (not Make)           | The hook killed `make` after `LINT_TIMEOUT`.                                                  |
| other | Linter / docker           | Unexpected error (docker daemon down, image pull failure, etc.).                              |

Codes `64` and `65` follow `sysexits.h` convention:

- `64` = `EX_USAGE` (we use it for "policy gap").
- `65` = `EX_DATAERR` (we use it for "linter wiring is broken").

### Make wrapping

GNU make wraps any non-zero recipe exit to its own status `2` and prints `make: *** [Makefile:N: lint] Error <code>` on stderr. The hook recovers `<code>` from that line so the structured response keeps the precise signal (`64` ≠ `65` ≠ `1`). The body of the agent message contains both the recipe's own stderr AND make's wrapper line — both useful context for the agent.

---

## Required environment

| Variable        | Effect                                                                          |
| --------------- | ------------------------------------------------------------------------------- |
| `FILE`          | The repo-relative path. **Required**.                                            |
| `LINT_VERBOSE`  | If `1`, branches MAY print extra context to stdout (project-defined).           |

Anything else passed through `$ENV` is allowed but not contractual.

---

## Routing table (single source of truth)

The routing table lives inline in the `lint:` recipe of the root `Makefile`. There is **no** companion config file, **no** dispatcher script, **no** per-extension sub-target. Reading the recipe IS reading the policy. Example shape (extension-only project):

```make
lint:
	@F='$(FILE)'; \
	case "$$F" in \
	  '') printf 'lint: FILE=... is required\n' >&2; exit 64 ;; \
	  node_modules/*|dist/*|.git/*|vendor/*) exit 0 ;; \
	  *.png|*.lock|*.env) exit 0 ;; \
	  *.md|*.mdc) exec docker run --rm -v "$$(pwd):/work" -w /work davidanson/markdownlint-cli2:latest "$$F" ;; \
	  *.yml|*.yaml) exec docker run --rm -v "$$(pwd):/work" -w /work cytopia/yamllint:latest -s "$$F" ;; \
	  *.json) exec docker run --rm -v "$$(pwd):/work" -w /work ghcr.io/jqlang/jq:latest empty "$$F" >/dev/null ;; \
	  *.sh|*.bash) exec docker run --rm -v "$$(pwd):/work" -w /work koalaman/shellcheck-alpine:stable shellcheck --severity=warning "$$F" ;; \
	  *) printf 'lint router: no case matches "%s".\n' "$$F" >&2; exit 64 ;; \
	esac
```

For monorepo projects, add workspace branches BEFORE the generic extension branches and strip the workspace prefix:

```make
	  apps/frontend/*) exec docker compose exec -T frontend npm run lint -- "$${F#apps/frontend/}" ;; \
	  apps/api/*) exec docker compose exec -T api ruff check "$${F#apps/api/}" ;; \
```

POSIX `case` globbing applies — `*` matches any sequence of characters including `/`, so `*.md` matches `docs/a/b/c.md`.

---

## Adding a new file type

1. Edit the `lint:` recipe of the root `Makefile`.
2. Add a new `case` branch BEFORE the catch-all.
3. Choose: `IGNORE` (→ `exit 0`), workspace branch (`docker compose exec -T <svc>` with prefix strip), or generic branch (`exec docker run …`).
4. Commit.

There is no other file to touch. The hook is path-agnostic and stack-agnostic; the recipe is the policy.

---

## Concurrency

The `make lint` target MUST be **safe to invoke concurrently** against different files. Because each invocation `exec`'s into its own docker container, isolation is by-construction. Projects that share a long-lived linter daemon (e.g. Biome) MUST scope the daemon's lock to its own container — never the host.

---

## Versioning

This contract is at **v2.0.0** (post-refactor). Breaking changes vs. v1.x:

- Removed `scripts/lint-route.sh` (no external dispatcher).
- Removed per-extension `lint-<ext>` sub-targets (no shell helpers).
- Routing table is now the body of the `lint:` recipe itself.

Adding new branches is a minor bump. Renaming `FILE` or changing the `64`/`65` semantics is a major.
