---
name: e2e-playwright
description: >-
  End-to-end testing with Playwright using a dedicated Docker Compose
  environment. Use when setting up E2E tests, writing Playwright specs,
  configuring test infrastructure, or debugging E2E CI pipelines.
tags:
  - docker
  - e2e
  - testing
---

# E2E testing: Playwright + Docker Compose

Playwright runs in a container, orchestrated by a dedicated `compose.e2e.yml`.
Never run the suite on the host.

## Templates (`templates/`)

| File | Purpose |
|:---|:---|
| `compose.playwright-service.yml` | `playwright` service for the main `compose.yml`, behind `profiles: [e2e]` |
| `compose.e2e.yml` | Environment overrides only (test mode, auth off, fake LLM, timing, video, workers) |
| `Dockerfile.e2e` | Runner image (keep the tag equal to the `@playwright/test` version) |
| `playwright.config.ts` | 3 browsers, HTML + JSON reports, trace/screenshot on failure, video mode |
| `test-users.fixture.ts` | Pool of 20 test users, one per spec file (`FILE_USER_MAP`) |
| `global-setup.ts`, `global-teardown.ts` | Reset + seed before, cleanup after |

## Principles

- **Idempotent**: a test can run N times. Setup starts with a reset, so a
  failed previous teardown cannot poison the run. Each test cleans what it
  created (`afterEach` or fixture teardown) and uses unique ids (UUID).
- **Parallel**: one test user per spec file, no shared state between files;
  tests within a file run sequentially. `fullyParallel: true`.
- **Isolated and reproducible**: environment fully defined by Compose; env
  vars control timing and video.

## Run

```bash
E2E="docker compose -f compose.yml -f compose.e2e.yml --profile e2e"
$E2E up --build --abort-on-container-exit --exit-code-from playwright
E2E_VIDEO_MODE=on $E2E up --build --abort-on-container-exit --exit-code-from playwright
E2E_ACTION_DELAY_MS=800 $E2E up --build ...   # visual debugging
$E2E down -v                                  # clean up
```

| Variable | Default | Meaning |
|:---|:---|:---|
| `E2E_ACTION_DELAY_MS` | `50` | Delay between actions (500-1000 to debug visually) |
| `E2E_VIDEO_MODE` | `off` | `off`, `on`, `retain-on-failure`, `on-first-retry` |
| `E2E_WORKERS` | `4` | Parallel workers |

## Reports

Always written to `playwright-report/` (add it to `.gitignore`): `index.html`
for humans, `results.json` for LLMs and CI (mandatory), `test-results/` for
artifacts.

## Test data

Provision through `/api/test/*` endpoints (exposed only when
`NODE_ENV=test`) or, with Prisma/TypeORM, a direct DB cleanup script run via
`docker compose exec`.

## CI

Run the same `up --abort-on-container-exit --exit-code-from playwright`
command in the job, then upload `playwright-report/` with
`actions/upload-artifact` under `if: always()`.

## Checklist

- [ ] `playwright` service under `profiles: [e2e]`; `compose.e2e.yml` overrides
- [ ] Runner Dockerfile; config with JSON + HTML reports; `.gitignore` entry
- [ ] 20+ test users and a `FILE_USER_MAP` entry per spec file
- [ ] Seed/cleanup implemented and restricted to `NODE_ENV=test`
- [ ] Idempotence verified: two consecutive runs pass
