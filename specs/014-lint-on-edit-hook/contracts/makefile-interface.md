# Contract — Makefile router (`make lint`)

**Owner**: root `Makefile` + `scripts/lint-route.sh`.
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

The `lint` target MUST:

1. Delegate to `scripts/lint-route.sh "$(FILE)"`.
2. NOT run any linter directly. Routing logic lives in the dispatcher; linter invocation lives in `lint-<ext>` sub-targets.
3. Propagate the dispatcher's exit code verbatim.

The dispatcher (`scripts/lint-route.sh`) MUST:

1. Reject empty `FILE` with a usage message + exit `64`.
2. Check the path against `LINT_EXCLUDED_PATHS`. If matched → exit `0`.
3. Extract the file extension.
4. Look up the extension in `LINT_IGNORED`. If matched → exit `0`.
5. Look up the extension in `LINT_ROUTES`. If found → `exec make lint-<sub-target> FILE="$FILE"`.
6. Otherwise → emit a policy-gap message and exit `64`.

---

## Exit-code contract

| Code  | Emitter           | Meaning                                                                                   |
| ----- | ----------------- | ----------------------------------------------------------------------------------------- |
| `0`   | Dispatcher        | Path or extension is ignored / excluded by design.                                         |
| `0`   | Sub-target        | Lint passed.                                                                               |
| `1`   | Sub-target        | Lint ran AND found violations.                                                             |
| `64`  | Dispatcher        | Policy gap: extension is in neither `LINT_ROUTES` nor `LINT_IGNORED`.                      |
| `64`  | Dispatcher        | Usage error: empty `FILE`.                                                                 |
| `65`  | Sub-target        | Wiring missing: linter binary absent, service not running, broken `package.json` script.   |
| `124` | Hook (not Make)   | The hook killed `make` after `LINT_TIMEOUT`.                                               |
| other | Sub-target / Make | Unexpected error (Docker down, container crash, etc.). Hook treats as a generic failure.   |

Codes `64` and `65` are this repo's **convention**, modelled on `sysexits.h`:

- `64` = `EX_USAGE` (we use it for "policy gap").
- `65` = `EX_DATAERR` (we use it for "linter wiring is broken").

The hook does NOT parse the message body to distinguish these — the exit code is the contract.

---

## Required environment

| Variable        | Effect                                                                          |
| --------------- | ------------------------------------------------------------------------------- |
| `FILE`          | The repo-relative path. **Required**.                                            |
| `LINT_VERBOSE`  | If `1`, sub-targets MAY print extra context to stdout.                          |
| `LINT_FORMAT`   | Reserved. v1 ships `text` only. `json` is documented but not required.          |

Anything else passed through `$ENV` is allowed but not contractual.

---

## Routing table (single source of truth)

Lives in `scripts/lint-route.sh`, as constants near the top of the file:

```bash
LINT_ROUTES=(
  ".ts:lint-ts"  ".tsx:lint-ts"
  ".js:lint-js"  ".jsx:lint-js"
  ".json:lint-json"
  ".yml:lint-yaml" ".yaml:lint-yaml"
  ".md:lint-md"    ".mdc:lint-md"
  ".sh:lint-sh"    ".bash:lint-sh"
  ".py:lint-py"
  ".go:lint-go"
  ".rs:lint-rs"
)

LINT_IGNORED=(
  ".png" ".jpg" ".jpeg" ".gif" ".webp" ".svg" ".ico"
  ".woff" ".woff2" ".ttf" ".eot"
  ".lock" ".lockb"
  ".pdf" ".zip" ".tar" ".tgz" ".gz"
  ".env" ".envrc"
)

LINT_EXCLUDED_PATHS=(
  "node_modules/" "dist/" "build/" ".next/" ".nuxt/"
  ".git/" ".cache/" "coverage/" "vendor/" ".venv/"
)
```

(Bash 3.2-compatible array of `extension:target` pairs — NOT a `declare -A` associative array, which is Bash 4+.)

---

## Sub-target convention

Every `lint-<ext>` target MUST:

1. Be `.PHONY`.
2. Take `FILE=…` as its only contractual input.
3. Run inside Docker. **No** host-installed linter assumption.
4. Detect missing wiring at startup and exit `65` BEFORE invoking the linter. Example checks:
   - Required service is `Up` (`docker compose ps <svc> | grep ' Up '`).
   - Required binary is present in the container (`command -v <linter>`).
5. Invoke the linter against `$(FILE)`.
6. Propagate exit `0` (pass) or `1` (violations). Never swallow violations.
7. Print ONLY the linter output. No decorative banner.

Reference templates for TS, JS, JSON, MD, YAML, SH, PY, GO live in `skills/makefile-lint-router/examples/` (created in Phase 5 of the plan).

---

## Concurrency

The `make lint` target MUST be **safe to invoke concurrently** against different files. If the implementation needs a per-target lock (e.g. shared Biome daemon), the lock MUST be:

- Scoped to that single sub-target.
- Free of stale-lock corruption (PID-checked or `flock(1)`-based).
- Documented in the sub-target's body comments.

The dispatcher itself is stateless and concurrent-safe by construction.

---

## Versioning

This contract is at **v1.0.0**. Breaking changes (renamed `FILE` env, new mandatory env, removed `64`/`65` exit codes) MUST bump the major. Adding a new exit code or a new sub-target template is a minor bump.
