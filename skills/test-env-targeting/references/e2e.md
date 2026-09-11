# End-to-end (browser) tests

Read this when a test drives a browser against `E2E_BASE_URL`. Common rules
(R1–R8) are in `SKILL.md`. Container orchestration for the local stack is the
`e2e-playwright` skill; this file covers how the suite targets a deployment.

## Playwright: three settings carry the target

```ts
use: { baseURL: env.E2E_BASE_URL }                 // page.goto("/") resolves here
globalSetup: "./shared/wait-for-target.ts"         // both origins answer, or fail
projects: [ { name: "e2e", grep: /@fast/ }, … ]    // lanes, never environments
```

All three are in `templates/typescript/playwright.config.ts`. What changes
between local and staging is `env`, evaluated once at config load. The
config file itself has no branch on an environment name.

**No `webServer`.** Playwright's `webServer` waits for one URL and expects to
own the process that serves it. A compose stack serves two origins (frontend
and API), and `make up` owns it. Using `webServer` for it means either
`up -d`, which Playwright rejects as "exited early", or a foreground `up`
whose readiness URL proves only the frontend — an API-only run then starts
before the backend answers. The template therefore:

- lets the Makefile depend on `up` for `ENV=local` (`STACK` variable), so the
  stack is started with compose healthchecks, outside Playwright;
- checks in `globalSetup` that `E2E_BASE_URL` and `API_BASE_URL` both answer,
  for every target, and fails with "run `make up` first" locally or "check the
  URL and your network access" remotely.

bill-e's `PLAYWRIGHT_SKIP_STACK=1` and `withStack` branch disappear: there is
no stack to skip inside the runner.

**`projects`** encode categories (`api`, `e2e`) and nothing else. A
`staging` project would duplicate each lane and diverge on demo data; the
environment is not a project. A lane is not a project either: Playwright
ANDs a project-level `grep` with the CLI `--grep`, so a project pinned to
`/@fast/`, as in `modelo-calendar/apps/e2e/playwright.config.ts`, drops every
spec without that tag from `make test-e2e`, including a `@prod-safe` smoke.
Lanes are `make test-e2e LANE=fast`; the Makefile composes the `--grep` and
ANDs it with `@prod-safe` on prod through lookaheads.

## Cypress equivalents

Cypress maps `CYPRESS_*` environment variables onto config keys, so the same
`with-env.sh` works with one alias in the Makefile:

```make
test-e2e-cypress: ## Cypress against ENV
	$(WITH_ENV) sh -c 'CYPRESS_BASE_URL=$$E2E_BASE_URL npx cypress run --env TEST_ENV=$$TEST_ENV'
```

`cypress/config/staging.json` files with literal URLs are the same drift as
a `staging.bru`: a second copy of `tests/env/.env.staging`.

## Authentication state per environment

Playwright's `storageState` saves cookies and local storage to a file after a
login, so later tests skip the form. That file is environment-specific: a
staging session replayed against local is a confusing 401. Key the path by
`TEST_ENV` and keep the directory out of git (`gitignore.snippet` lists it):

```ts
// tests/e2e/auth.setup.ts — a "setup" project the e2e projects depend on
import { test as setup } from "../shared/fixtures";
import { env, requireUser } from "../shared/env";

const authFile = `tests/.auth/${env.TEST_ENV}.json`;

setup("authenticate", async ({ page }) => {
  const { email, password } = requireUser();
  await page.goto("/login");
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.waitForURL("**/dashboard");
  await page.context().storageState({ path: authFile });
});
```

```ts
projects: [
  { name: "setup", testMatch: /auth\.setup\.ts/ },
  { name: "e2e", dependencies: ["setup"], use: { storageState: `tests/.auth/${env.TEST_ENV}.json`, … } },
]
```

On prod there is no demo identity, so the `setup` project must not run: give
it `grep: /@prod-safe/` with no such tag, or exclude it in the Makefile with
`--project e2e` and no dependency chain for the prod lane. The template keeps
the simpler form (login inside the test) so the prod path stays obvious.

## Test data on a shared staging

Local can reset its database between runs. Staging cannot, and several people
and pipelines share it. The `@business` tests that create data therefore:

- create with a run-scoped marker (`e2e-staging-<timestamp>` in a name field);
- delete what they created in the same test, through the API when the UI has
  no delete path. The `request` fixture in an e2e spec resolves against the
  e2e project's `baseURL`, the frontend; build an API context explicitly:
  `const api = await playwright.request.newContext({ baseURL: env.API_BASE_URL })`;
- run through `make test-e2e-business`, which passes `--grep @business
  --workers=1` and refuses `ENV=prod`, as bill-e does with `E2E_BUSINESS_GREP`;
- own their identity: one demo account per parallel file when files run in
  parallel, which is the `e2e-playwright` skill's provisioning pattern.

A leftover row on staging is a bug in the test, filed as such.

## Prod: the read-only allowlist

Prod e2e is synthetic monitoring under another name, and the same limits
apply: a handful of anonymous journeys, each tagged `@prod-safe`, each
asserting that a page renders and a public read succeeds. The suite is
listed before every run:

```bash
make test-e2e-list ENV=prod PROD_CONFIRM=1
make test-e2e ENV=prod PROD_CONFIRM=1
```

The `prodGuard` auto fixture in `shared/fixtures.ts` fails any test that
reaches prod without the tag, even when the `--grep` filter was forgotten.
A test that logs in is never prod-safe: `.env.prod` carries no identity and
the schema rejects a loaded password. Authenticated synthetic monitoring is a
separate, reviewed entry point outside this skill.

## Visual and timing knobs stay out of `tests/env/`

`SLOW_MO`, `VIDEO`, `FAST_RETRIES`, `PLAYWRIGHT_GREP` are run knobs, not
target properties. They stay as plain environment variables read in the
config, defaulted in code, and passed on the command line. Putting them in
`.env.staging` would make a staging run slower by definition.

## Checklist for a new e2e suite

- [ ] `use.baseURL: env.E2E_BASE_URL`; no `||` default in the config.
- [ ] No `webServer`; `globalSetup` is `wait-for-target.ts`; `make test-e2e` depends on `up` when local.
- [ ] Projects are categories only; no project named after an environment or a lane.
- [ ] Specs import `test` from `shared/fixtures`.
- [ ] `storageState` path keyed by `TEST_ENV`, directory gitignored.
- [ ] `@prod-safe` on anonymous read journeys only; `@business` through `test-e2e-business`.
- [ ] `make test-e2e`, `test-e2e-list` and `test-e2e-business` in `Makefile.tests.mk`.
