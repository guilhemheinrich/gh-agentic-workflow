# Integration tests

Read this when a test exercises an adapter against a real backing service:
a database, a queue, a cache, an object store, another service of the same
stack. The common rules (R1–R8) are in `SKILL.md`; this file adds what is
specific to the category.

## The one rule that differs: integration targets local

An integration test owns its data. It creates a row, asserts on it, rolls it
back. That contract holds only against a store the test controls, which means
the compose stack or a testcontainer on the same machine. Against staging the
store is shared, migrations may lag, and a rollback is a hope.

So `TEST_ENV=staging` is refused by the integration entry points unless the
caller adds `TEST_LIVE=1`, and `TEST_ENV=prod` is refused whatever the flags:

```bash
make test-integration                           # local, the normal case
make test-integration ENV=staging TEST_LIVE=1   # the live lane, on purpose
make test-integration ENV=prod PROD_CONFIRM=1   # exit 2: never targets prod
```

The refusal lives in three places: the Makefile target exits before calling
the loader on `ENV=prod`; `global-setup.ts` and `Env.RequireLocal(t)` refuse
prod again and demand `TEST_LIVE=1` for any other remote target. `TEST_LIVE`
follows the `PROD_CONFIRM` rule: the Makefile turns it into `with-env.sh
--live` only when typed on the make command line, the loader discards a
`TEST_LIVE` found in a file or in the ambient environment, and the Node and
Go fallbacks accept it only behind the loader's `TEST_ENV_LOADER` marker.

## What "live" means, and where it lives

A live test needs infrastructure that the default stack does not start:
Prometheus, a bootstrapped Kong, a three-node topology. It is still an
integration test in shape, so it reads the same `tests/env/` files, but it is
excluded from the default scope and runs through its own entry point.

`modelo-broker-api/apps/backend/jest.live.config.js` is the fleet's example:
a second Jest config that spreads the base one and lists `testMatch` for the
`test/live/**` suites, each documented with the `make` target and the compose
overlay that brings its infrastructure up. Copy that shape:

- one config file per scope (`vitest.integration.config.ts`, `jest.live.config.js`),
  never a `describe.skip` sprinkled inside shared files;
- one `make` target per scope, both calling `with-env.sh`;
- the extra variables a live scope needs (`OBSERVABILITY_TEST_FIXTURES`,
  `KONG_ADMIN_URL`) go into `tests/env/.env.local`, optional in the schema.

## Local backing services: compose or testcontainers

Two ways to get the store, both reading `DATABASE_URL` from `.env.local`:

**Compose, already up.** The stack `make up` started is the store. The
integration config does not start anything; `global-setup.ts` may apply
migrations. This is the fleet default and the cheapest to reason about:
`docker compose ps` shows what the tests hit.

**Testcontainers, per run.** The test starts a fresh Postgres and gets its
URL from code, not from the file. In Vitest, `globalSetup` runs in the main
process and the workers evaluate `env.ts` on their own, so a
`process.env.DATABASE_URL` set there is not seen by the tests. Pass it with
`project.provide("databaseUrl", url)` in the global setup and
`inject("databaseUrl")` in the spec, and build the client from that value.
Go is simpler: `testcontainers-go` in `TestMain`, then
`os.Setenv("DATABASE_URL", …)` before any `testenv.Load`, in the same
process. Use testcontainers when the suite must run on a machine with Docker
but without the project's compose file, for example a shared CI runner. It
costs 5 to 20 s of container start per run.

With compose the test reads `env.DATABASE_URL`; with testcontainers it reads
the injected value. Keep one path per repo.

## In-process vs over-the-wire

The categories blur at the edge of a backend. Decide by what is being tested:

| The test asserts on                              | Category    | Reads                                   |
| ------------------------------------------------ | ----------- | --------------------------------------- |
| a repository, a client adapter, a migration      | integration | `DATABASE_URL`, service URLs, local only |
| a route through the framework, app in-process    | integration | nothing remote; app booted in the test  |
| a route over HTTP against a deployment           | API         | `API_BASE_URL` — see `api.md`           |

A NestJS `app.getHttpServer()` with supertest is integration: the app runs in
the test process, only its backing services are external. It reads
`DATABASE_URL` and never `API_BASE_URL`. The same assertions against staging
belong in an API test.

## Isolation and idempotence

- **Transaction per test, rolled back.** `BEGIN` in `beforeEach`, `ROLLBACK`
  in `afterEach` (TypeScript template), or `db.BeginTx` with `t.Cleanup(tx.Rollback)`
  (Go template). Files then run in any order and can run in parallel across
  databases, not across one.
- **`fileParallelism: false`** in the Vitest config while there is one shared
  database. Lift it when each worker gets its own schema or container.
- **Run-scoped names** (`it-<timestamp>`) even inside a transaction: when a
  rollback fails, the leftover is attributable.
- **No `t.Skip` on missing env.** `main_smoke_test.go` in bill-e skips its
  iframe test when variables are absent, so that `go test ./...` stays green
  without the stack. The build tag already gives that guarantee: without
  `-tags smoke` the file is not compiled. Inside the tag, a missing variable
  is a failure with a message, not a skip.

## Go specifics

Build tags are the category switch and the reason `go test ./...` stays fast:

```go
//go:build integration
```

`go vet` and `gopls` ignore tagged files unless the tag is set. Add
`"go.buildFlags": ["-tags=integration,api"]` to the workspace settings when
editing them, or the IDE reports the package as empty.

`testenv.Load(t)` is called at the top of each test, not in `TestMain`: a
failure then attributes to the test that needed the variable, and `-run`
filters still work without loading anything.

## Checklist for a new integration suite

- [ ] Config file dedicated to the scope, `setupFiles` imports `shared/env.ts`.
- [ ] `global-setup` refuses remote targets without `TEST_LIVE=1`.
- [ ] `DATABASE_URL` and service URLs in `tests/env/.env.local`, optional in the schema.
- [ ] Transaction per test, rolled back; `fileParallelism: false` or per-worker schema.
- [ ] `make test-integration` in `Makefile.tests.mk`; Go twin with `-tags integration`.
- [ ] No `describe.skip`, no `t.Skip` on missing variables.
