# API tests

Read this when a test sends HTTP to a deployed backend and asserts on the
response. The target is `API_BASE_URL`; the deployment may be local, staging
or prod. Common rules (R1–R8) are in `SKILL.md`.

## Two ways to write them, same variables

**In code** — Playwright's `request` fixture, or `fetch`, or Go `net/http`.
Best when assertions need logic: chained calls, token handling, cleanup.
Template: `templates/typescript/api/health.api.spec.ts`,
`templates/go/api/health_api_test.go`.

**Declarative** — Bruno, Hurl, Newman/Postman. Best when the collection is
also documentation, or when non-developers maintain it. The runner still gets
its target from `with-env.sh`; the collection references variables, never
values.

Pick one per repo. Two API layers with two variable namings is the drift this
skill exists to remove.

## Playwright `request`: a project, not a second config

The `api` project in `templates/typescript/playwright.config.ts` sets
`use.baseURL` to `env.API_BASE_URL` and `testDir` to `./api`. Specs then call
`request.get("/health")` with a relative path. One config serves API and e2e
because both read the same `env`, and `make test-api` is a `--project api`
filter away from `make test-e2e`.

The `request` fixture is a fresh `APIRequestContext` per test: no cookie or
token leaks between tests. For an authenticated sequence, log in inside the
test (template) or use a worker-scoped fixture that logs in once and exposes
the token. Do not persist API tokens to disk between runs; the browser
`storageState` pattern in `e2e.md` is for cookies the UI needs, not for API
bearer tokens.

## Tagging: what may hit which target

| Endpoint kind                  | Tag                     | Runs on prod |
| ------------------------------ | ----------------------- | ------------ |
| `GET /health`, `GET /version`  | `@prod-safe @smoke`     | yes          |
| authenticated `GET` as demo    | untagged or `@smoke`: prod has no identity | no |
| any `POST`/`PUT`/`DELETE`      | `@business`             | never        |

A `GET` is not automatically prod-safe: a `GET /reports/export` that enqueues
a job has a side effect. Tag by effect, not by verb.

`@business` tests create data on a shared staging. They therefore:

- carry a run-scoped marker in every created entity (`e2e-staging-<timestamp>`);
- read the created id before any assertion and delete in `finally` or
  `t.Cleanup`, as the templates do, so a failing assertion never leaves the
  row behind; never rely on a global teardown that a crash skips;
- run through `make test-api-business`, which passes `--workers=1` because
  they share one demo account, as bill-e does with `E2E_BUSINESS_GREP` in
  `tests/e2e/package.json`. The target refuses `ENV=prod`.

## Go: build tag plus name allowlist

```go
//go:build api
```

keeps `go test ./...` from compiling network tests. On prod the Makefile adds
`-run '^TestProdSafe_'` — anchored, since `-run` is a regular expression and
`TestNotProdSafe_Delete` would otherwise match. The allowlist is therefore a
naming convention: `TestProdSafe_Health`, `TestProdSafe_Version`. Every
mutating test calls `env.RequireWrites(t)` first, which fails on prod even if
the `-run` filter was forgotten. Both locks are in the template, and the
second one exists only in tests that call it.

## Declarative runners

All three read the variables `with-env.sh` exported. None needs an
environment file of its own.

**Hurl.** A variable `api_base_url` is defined by the environment variable
`HURL_api_base_url`. Bridge it in the Makefile, and Hurl files stay
target-free:

```make
test-api-hurl: ## Hurl collection against ENV
	$(WITH_ENV) sh -c 'HURL_api_base_url=$$API_BASE_URL hurl --test tests/api/hurl/*.hurl'
```

```hurl
GET {{api_base_url}}/health
HTTP 200
```

**Bruno.** Keep one Bruno environment, `env`, whose values are process
lookups, so `bru run` gets the target from the shell:

```text
vars {
  api_base_url: {{process.env.API_BASE_URL}}
  user_email: {{process.env.TEST_USER_EMAIL}}
}
vars:secret [
  user_password
]
```

```make
test-api-bru: ## Bruno collection against ENV
	$(WITH_ENV) sh -c 'bru run tests/api/bruno --env env --env-var user_password=$$TEST_USER_PASSWORD'
```

Bruno never persists a `vars:secret` value; the `--env-var` flag supplies it
per run. A `staging.bru` environment with literal URLs is the anti-pattern:
it is a second copy of `tests/env/.env.staging`.

**Newman.** `newman run collection.json --env-var baseUrl=$API_BASE_URL`.
Same idea; a committed `staging.postman_environment.json` is the same drift.

## Prod: what an API smoke may do

- Anonymous `GET`s on health and version endpoints.
- A `GET` on a public, cacheable resource, asserting status and schema, never
  content that changes.
- Nothing authenticated. The schema rejects a loaded password on prod;
  authenticated synthetic checks are a separate, reviewed entry point that
  this skill does not ship.

Before running: `make test-api-list ENV=prod PROD_CONFIRM=1`, read the list,
then `make test-api ENV=prod PROD_CONFIRM=1`.

## Checklist for a new API suite

- [ ] `api` project with `baseURL: env.API_BASE_URL`; specs use relative paths.
- [ ] Specs import `test` from `shared/fixtures`, never from `@playwright/test`.
- [ ] Read-only endpoints tagged `@prod-safe`; mutating ones `@business` with cleanup.
- [ ] Go files tagged `//go:build api`; read-only tests named `TestProdSafe_*`.
- [ ] Declarative collections reference variables only; no per-environment collection file.
- [ ] `make test-api`, `test-api-list` and `test-api-business` in `Makefile.tests.mk`.
