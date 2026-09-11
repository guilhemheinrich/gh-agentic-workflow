---
name: test-env-targeting
description: >-
  Point integration, API, e2e and load tests at local, staging or prod with one
  selector and one set of environment files shared by every category. Covers
  the four layers every runner needs — `TEST_ENV` selection, committed
  `tests/env/.env.<env>` files with a gitignored `.secret` sibling, a typed
  schema that fails before the first test, and tag gating with a prod lock
  (`PROD_CONFIRM=1` plus a `@prod-safe` allowlist). Loads the environment at
  the shell level through `with-env.sh`, so Playwright, Vitest, `go test`, k6,
  Hurl and Bruno read plain variables and no runner carries a dotenv parser.
  Ships env-file templates, the Makefile entry points, TypeScript (zod,
  Playwright, Vitest) and Go (stdlib, build tags) templates, and one reference
  per category. Use when adding a test category to a repo, running an existing
  suite against staging or prod, unifying `E2E_BASE_URL` / `BASE_URL` naming
  across a fleet, or reviewing a test config that hardcodes a target.
tags:
  - testing
  - e2e
  - playwright
  - vitest
  - make
  - shell
  - typescript
  - validation
---

# Test Environment Targeting

A test is a client that points at a deployment. Which deployment is an input,
not a property of the test. This skill fixes how that input is named, stored,
validated and gated, once, for every test category in a repo.

```text
 make test-e2e ENV=staging LANE=fast
        │
        ▼
 tests/env/with-env.sh staging -- <runner>      ① SELECT   one variable: TEST_ENV
        │  .env.staging          (committed)    ② LOAD     caller wins > .secret > file
        │  .env.staging.secret   (gitignored)              grammar-checked, prod hosts refused
        ▼
 tests/shared/env.ts · internal/testenv         ③ VALIDATE typed, fails before test #1
        │
        ▼
 @prod-safe · @business · @fast · @slow         ④ GATE     tags decide what may run here
        │
        ▼
 Playwright · Vitest · go test · k6 · Hurl      read process.env / os.Getenv / __ENV
```

## 1. What is in this bundle

| File                                              | Role                                                           |
| ------------------------------------------------- | -------------------------------------------------------------- |
| `templates/env/.env.local` `.env.staging` `.env.prod` | One committed file per environment, same schema.           |
| `templates/env/.env.local.secret.example` `.env.staging.secret.example` | Shape of the gitignored secret siblings. Prod has none. |
| `templates/env/gitignore.snippet`                 | The two lines to add to the repo `.gitignore`.                 |
| `templates/env/with-env.sh`                       | The loader: grammar check, precedence, run flags, prod locks, `exec`. |
| `templates/Makefile.tests.mk`                     | `test-api`, `test-e2e`, their `-list` and `-business` twins, `test-integration`, Go twins, `test-load-smoke`. |
| `templates/typescript/shared/env.ts`              | zod schema, `isRemote`, `writesAllowed`, `requireUser()`.      |
| `templates/typescript/shared/fixtures.ts`         | Playwright `test` with the prod guard as an auto fixture.      |
| `templates/typescript/shared/wait-for-target.ts`  | Playwright `globalSetup`: both origins answer, or fail with the fix. |
| `templates/typescript/playwright.config.ts`       | Projects = categories only; no `webServer`, no lane `grep`.    |
| `templates/typescript/api/` `e2e/` `integration/` | One worked spec per category, Vitest integration config and global setup. |
| `templates/go/testenv/testenv.go`                 | Stdlib loader and validator with the same locks.               |
| `templates/go/api/` `integration/`                | Build-tagged Go tests, `TestProdSafe_*` allowlist.             |
| `references/integration.md`                      | Backing services, in-process vs live lane, testcontainers.     |
| `references/api.md`                               | HTTP tests in code and declarative (Bruno, Hurl, Newman).      |
| `references/e2e.md`                               | Playwright and Cypress: baseURL, readiness, auth state, data.  |
| `references/load.md`                              | k6 with the same variables.                                    |

Read this file for the rules. Open one reference only when you work on that
category. The templates are copied, then adapted: paths, module names and the
example endpoints (`/health`, `/items`) are placeholders. A repo with a single
surface (API only, or frontend only) deletes the other `*_BASE_URL` from the
schema, its Playwright project and its wait in `wait-for-target.ts`.

## 2. The eight rules

### R1. One selector: `TEST_ENV`

`TEST_ENV=local|staging|prod`, default `local`. It selects the file to load
and the policy to apply: which locks, which tags, which categories may run.
Nothing else selects it: not the hostname, not `CI=true`, not the presence of
a file. A runner that guesses is a runner that one day guesses prod.

URLs may still be overridden by the caller (R3), so the loader also checks
the destination: a `*_BASE_URL` whose host is declared in `.env.prod` is
refused unless `TEST_ENV=prod`. `E2E_BASE_URL=https://app.example.com make
test-e2e ENV=local` therefore exits 2 instead of running the local suite,
with its writes, against production.

### R2. One set of files per environment, shared by every category

```text
tests/env/.env.local            committed — compose defaults
tests/env/.env.staging          committed — staging URLs, demo account names
tests/env/.env.prod             committed — URLs only
tests/env/.env.<env>.secret     gitignored — passwords, tokens
tests/env/with-env.sh           the loader
```

Integration, API, e2e and load tests read the same three files. A category
never owns its own `.env`. The files share one schema; a key that only one
environment needs (`DATABASE_URL` for local integration) is present there and
optional in the schema, not padded into the others.

The secret sibling is named `.secret`, not the dotenv-flow `.local`: with an
environment called `local`, `.env.local.local` reads as a typo. The files live
under `tests/env/`, so Vite and Next never pick them up as app config.

The files obey a strict grammar, checked by the loader before anything is
sourced: `KEY=VALUE`, blank lines, full-line comments, single or double quotes
around the whole value, no `$`, no backtick, no inline comment, no `export`.
The same grammar is what Node's `loadEnvFile` and the Go parser implement, so
one file means one value in bash, Node and Go, and a committed env file can
never execute a command.

### R3. Precedence: caller wins, then `.secret`, then the committed file

`with-env.sh` snapshots the caller's environment, sources the two files, then
re-applies the snapshot. A CI secret store, a `make VAR=…` override or a
compose `environment:` block therefore always beats a file. The Node fallback
(`process.loadEnvFile`) and the Go loader keep the same order by loading
`.secret` first and never overriding a variable already present.

The two run flags, `PROD_CONFIRM` and `TEST_LIVE`, are the exception: the
loader sets them from its own options and discards any value found in a file
or in the ambient environment. See R6.

Trap, real: a root Makefile with `-include .env` and `export` pushes the
application's runtime `.env` into every recipe, where it counts as "caller".
`modelo-bill-e` does this. An `E2E_BASE_URL` left in that root `.env` beats
`tests/env/.env.staging` silently. Test-target variables do not belong in the
app's `.env`.

### R4. Load at the shell level; runners read plain variables

The loader runs once, in front of the runner:

```bash
make test-e2e ENV=staging
bash tests/env/with-env.sh staging -- npx playwright test --project api
bash tests/env/with-env.sh local -- go test -tags integration ./...
bash tests/env/with-env.sh staging -- k6 run tests/load/smoke.js
```

Downstream there is no `dotenv` import, no hand-written parser, no
`--env-file` per runner. The 25-line `.env` parser at the top of
`modelo-bill-e/tests/e2e/playwright.config.ts` is what this rule deletes.
The only in-runner loading is the fallback in `env.ts` and `testenv.go`, so
that a bare `npx playwright test` or `go test` from an IDE still finds
`.env.local` or `.env.staging`. Both use the standard library and the same
precedence. Prod is not a bare-run target: the fallbacks honour
`PROD_CONFIRM` and `TEST_LIVE` only when `with-env.sh` left its
`TEST_ENV_LOADER=with-env` marker, and discard them otherwise. An
`export PROD_CONFIRM=1` in a shell profile therefore opens nothing on its own.

`with-env.sh` is bash. On Windows it runs under Git Bash or WSL; the Node and
Go fallbacks cover the IDE.

### R5. Validate with a typed schema before the first test

`tests/shared/env.ts` (zod) is imported by the Playwright config and the
Vitest setup file, so a missing variable fails the run at load time with one
message that names the file to fix:

```text
Invalid test environment for TEST_ENV=staging
  E2E_BASE_URL: Required
Expected in tests/env/.env.staging (secrets: .env.staging.secret), or exported by the caller.
```

Go has no config file to import from: `testenv.Load(t)` validates per test,
at its first line, and a test that does not call it is not validated. Every
test in a tagged package therefore starts with `env := testenv.Load(t)`.

No test reads `process.env` or `os.Getenv` directly. Tests import `env`.
Optional values that a journey needs are demanded loudly through
`requireUser()` / `RequireUser(t)`: a skip hides a misconfiguration, a failure
shows it. `modelo-hub/apps/auth-api/vitest.config.ci.ts` excludes a test
because ambient variables are missing in CI; under this rule the run would
have named them.

### R6. Gate by tags; prod is an allowlist behind locks

| Tag           | Meaning                                      | local | staging | prod |
| ------------- | -------------------------------------------- | ----- | ------- | ---- |
| `@prod-safe`  | anonymous read, no side effect               | yes   | yes     | yes  |
| `@smoke`      | fast health of the deployment                | yes   | yes     | if also `@prod-safe` |
| `@business`   | creates or mutates data, serial, cleans up   | yes   | yes     | never |
| `@fast` `@slow` | lane, orthogonal to the three above        | yes   | yes     | —    |

Prod is anonymous and read-only. `.env.prod` carries URLs only, has no
`.secret` sibling, and the schema rejects a loaded `TEST_USER_PASSWORD` when
`TEST_ENV=prod`. A repo that needs authenticated synthetic checks in prod
builds a separate, reviewed entry point; this skill does not ship one.

The locks, and where each one lives:

1. **Confirmation on the make command line.** `make … ENV=prod PROD_CONFIRM=1`
   becomes `with-env.sh --confirm-prod` only when make sees the assignment
   with origin `command line`. An `export PROD_CONFIRM=1` in a shell profile
   or a CI job has origin `environment` and is ignored; a `PROD_CONFIRM=1`
   line in any env file is discarded by all three loaders; the Node and Go
   fallbacks accept the flag only behind the loader's marker (R4).
2. **Allowlist by tag.** On prod the Makefile adds `--grep '(?=.*@prod-safe)'`
   (Go: `-run '^TestProdSafe_'`). The Playwright auto fixture in
   `shared/fixtures.ts` then fails any test that reached prod without the
   tag, for every spec that imports `test` from there. Go mutating tests call
   `env.RequireWrites(t)` as their own second lock.
3. **Categories that never target prod refuse first.** `test-integration`,
   `test-*-business` and `test-load-smoke` exit 2 on `ENV=prod` before calling
   the loader; `global-setup.ts` and `RequireLocal(t)` refuse prod again
   inside the runner.
4. **Destination check.** A non-prod run whose `*_BASE_URL` points at a host
   declared in `.env.prod` is refused (R1).

Before a prod run, list what would run, and read the list:

```bash
make test-e2e-list ENV=prod PROD_CONFIRM=1
make test-api-list ENV=prod PROD_CONFIRM=1
```

### R7. Environment, lane and mode are three axes

- **Environment** is `TEST_ENV`. It is never a Playwright project.
- **Lane** is speed or scope: `fast` / `slow`, `nightly-extended` in
  broker-api. It is a `--grep` the Makefile composes from `LANE=fast`, ANDed
  with the prod allowlist through lookaheads. The Makefile rejects a `LANE`
  outside its `LANES` list, because a mistyped tag matches nothing and a run
  of zero tests exits green. It is not a project-level
  `grep` either: Playwright ANDs a project `grep` with the CLI `--grep`, so a
  project pinned to `/@fast/` silently drops every spec that lacks the tag.
  `modelo-calendar/apps/e2e/playwright.config.ts` has that shape today.
- **Mode** is a runtime shape of the app: `.env.hub` and `.env.hubless` in
  bill-e and broker-pa. A staging hubless run makes sense. Modes stay in the
  app's own env files, not in `tests/env/`.

Projects encode the category (`api`, `e2e`), because a category has its own
`testDir` and `baseURL`. One project per environment, the pattern Playwright
Solutions warns against, multiplies lanes by environments and breaks the
moment demo data differs.

### R8. Canonical variable names

| Variable             | Meaning                                    | Source        |
| -------------------- | ------------------------------------------ | ------------- |
| `TEST_ENV`           | the selector                               | `ENV=` on make, or the file |
| `E2E_BASE_URL`       | frontend origin as seen from the runner    | committed file |
| `API_BASE_URL`       | backend origin as seen from the runner     | committed file |
| `DATABASE_URL`       | local backing store, integration only      | `.env.local`  |
| `TEST_USER_EMAIL`    | demo identity name                         | committed file |
| `TEST_USER_PASSWORD` | demo identity secret                       | `.secret` or CI store |
| `PROD_CONFIRM`       | prod lock, `1`                             | make command line only |
| `TEST_LIVE`          | opt a remote target into the live lane     | make command line only |

The fleet today uses `E2E_BASE_URL` (bill-e), `BASE_URL` (calendar, k6) and
`HUB_SHELL_BASE_URL` (hub-shell) for the same thing. Adopting a repo means
renaming to the two `*_BASE_URL` above, with a one-release alias if scripts
outside the repo depend on the old name. Both origins are http(s) URLs; the
schema rejects any other scheme.

## 3. Runner inside a container

URLs are written as seen from the runner. `.env.local` assumes a process on
the host (`http://127.0.0.1:5173`). When the runner is a compose service, as
in the `e2e-playwright` skill, the same variables carry service hostnames:

```yaml
services:
  playwright:
    environment:
      TEST_ENV: local
      E2E_BASE_URL: http://frontend:3101
      API_BASE_URL: http://backend:8080
```

That block is "caller environment" and wins over the file (R3). For a remote
target, pass the variables through instead of copying values:

```bash
docker compose run --rm -e TEST_ENV -e E2E_BASE_URL -e API_BASE_URL -e TEST_USER_EMAIL -e TEST_USER_PASSWORD -e PROD_CONFIRM playwright npx playwright test
```

`-e NAME` without a value forwards the host value, so `with-env.sh` in front
of `docker compose run` is enough, and `PROD_CONFIRM` reaches the container
only when the loader set it.

## 4. Adopting an existing repo

1. Create `tests/env/` from `templates/env/`; fill the three files with the
   repo's real URLs; add the two `gitignore.snippet` lines.
2. Copy `templates/Makefile.tests.mk` to `tests/Makefile.tests.mk` and add
   `include tests/Makefile.tests.mk` to the root Makefile, which must expose
   an `up` target. Check that root Makefile for `-include .env` (R3 trap).
3. TypeScript: copy `shared/`; replace every
   `process.env.X_BASE_URL || "http://…"` with `env.X_BASE_URL`; delete
   in-config `.env` parsers and `webServer` blocks; point specs at
   `../shared/fixtures`. Go: copy `testenv/` into the module; replace
   `os.Getenv` in tests with `testenv.Load(t)`.
4. Tag: mark anonymous read-only specs `@prod-safe`, mutating ones
   `@business`, and lanes `@fast` / `@slow` where the repo has them. Run
   `make test-e2e-list ENV=prod PROD_CONFIRM=1` and read the list.
5. Run each category against `local`, then `staging`. Only then decide
   whether prod is a target at all for this repo.

Then open the reference of the category you are changing.

## 5. Anti-patterns this skill replaces

| Seen in the fleet                                        | Rule |
| -------------------------------------------------------- | ---- |
| Hand-written `.env` parser in `playwright.config.ts`     | R4   |
| `BASE_URL \|\| "http://localhost:3000"` default in code  | R5   |
| No validation; CI excludes the test that needs a variable | R5   |
| One Playwright project per environment                   | R7   |
| Lane `grep` pinned on the only project the Makefile runs | R7   |
| Mode files (`.env.hub`) mistaken for target files        | R7   |
| Three names for the frontend URL across repos            | R8   |
| Prod reachable by editing `HUB_BASE_URL` in place         | R1, R6, and the note in `MODELO_HUB/.env.staging.example` |
