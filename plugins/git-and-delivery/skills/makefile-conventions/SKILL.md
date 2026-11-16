---
name: makefile-conventions
description: >-
  Write the project-root task runner (a Makefile or a Taskfile.yml) with
  Docker-first execution, .env-driven configuration, and standardized targets
  (up, down, test, lock, copy-vendors, test-e2e). Ships a Makefile and a
  Taskfile.yml template. Use when authoring or debugging Makefiles or
  Taskfiles, adding make targets or Task tasks, converting a Makefile to Task,
  or when the user mentions "Makefile", "Taskfile", "make up", "task up" or a
  docker compose workflow.
---

# Makefile / Taskfile conventions

Two drivers, same principles and same target names. A project picks **one** (two interfaces always diverge).

| Driver | File | Template |
|---|---|---|
| Make | `Makefile` | [templates/Makefile](templates/Makefile) |
| Task (v3) | `Taskfile.yml` | [templates/Taskfile.yml](templates/Taskfile.yml) |

Prefer Task when the project wants a declarative file, `task --list` as help, named arguments (`task logs -- api`) and an identical shell on every OS. `help` becomes the `default` task; `copy-lock` / `locks` becomes `lock`.

## Principles

1. **Docker-first**: every command runs in a container, never on the host (documented exceptions only, e.g. native mobile builds grouped under a `mobile:*` prefix).
2. **`.env`-driven**: ports, URLs and images come from `.env` with fallbacks identical to `.env.example`. Make: `-include .env` (leading dash: silent when absent) + `export` + `?=`. Task: `dotenv: ['.env']` + `${VAR:-default}`.
3. **Useful output**: after `up`, print every exposed URL (ports from variables, never hard-coded); after tests, print the report path, even on failure, while still propagating the exit code.
4. **Make only**: declare every non-file target `.PHONY`, set `.DEFAULT_GOAL := help`, `help` is generated from `## comment`.

Mandatory targets: `help`, `up`, `down`, `copy-vendors` (container `node_modules` to host for the IDE/LSP; delete the old directory first to avoid symlink conflicts; one `cp` per package in a monorepo), `lock` (regenerate the lockfile in the container and copy it to the host; a missing lockfile is a warning), `test`; plus `test-e2e` (dedicated `compose.e2e.yml` + `e2e` profile, wait for health, propagate Playwright's exit code, copy the report to a known path, restore the normal stack) and `test-api` when relevant.

## Make to Task

| Makefile | Taskfile.yml |
|---|---|
| `-include .env` + `export` | `dotenv: ['.env']` (absent file tolerated; does not override variables already in the environment) |
| `APP_PORT ?= 3000` | `${APP_PORT:-3000}` in commands, or `{{.APP_PORT \| default "3000"}}` in `vars:` |
| `.PHONY` | not needed |
| `help` + `## comment` | `desc:` on every task + `default` task running `task --list` |
| `$(call print_resource,...)` | a `resources` task (`silent: true`) with `printf` |
| `$(MAKE) copy-lock` | `- task: copy-lock` |
| `make test-e2e TAGS=a,b` | `task test-e2e -- a,b` via `{{.CLI_ARGS}}` |
| `@` | `silent: true` |
| `cd apps/x && ...` | `dir: apps/x` |
| manual confirmation | `prompt: "Delete volumes?"` |
| interactive `exec ... sh` | `interactive: true` |
| file targets | `sources:` / `generates:` |
| `$$` to escape `$` | plain `$`; `{{ }}` is reserved for Task templates |

Task gotchas:

- Commands run in a built-in POSIX interpreter (`mvdan/sh`): no bashisms (`[[ ]]`, arrays); write POSIX or call `bash -c` explicitly.
- `docker compose up --wait` replaces the Makefile health-check loop, provided every service declares a `healthcheck`.
- Quote YAML strings containing `{{ }}` or `:`.
- A multi-line `|` block runs in one shell: that is where local variables and exit-code propagation go.
- Every task needs a `desc:` (otherwise invisible in `task --list`); name tasks in kebab-case, group by domain with `:` (`db:migrate`).
- Install: <https://taskfile.dev/installation/>; GitHub Actions: `arduino/setup-task@v2` (`version: 3.x`).

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Hard-coded port (`localhost:3000`) | `http://localhost:$(APP_PORT)` |
| Command on the host (`npm test`, `pnpm install`) | `$(EXEC_BACKEND) npm test` / `{{.RUN_BACKEND}} pnpm ...` |
| `include .env` without the dash | `-include .env` |
| E2E without a printed report path | always print it |
| Silent `up` | list the exposed resources |
| `compose up -d` then immediate action, no wait | `--wait` + healthchecks, or a health loop |
| Makefile and Taskfile side by side | keep one |

Awk fields in the help recipe are written `$$(1)` / `$$(2)`: equivalent to `$$1`, and safe when a SKILL.md is invoked as a slash command (a bare `$` followed by a digit gets replaced by an argument).

## See also

Per-file linting on edit does not go through the Makefile or Taskfile: see [static-validation-hooks](agent-tooling:static-validation-hooks/SKILL.md) (the routing table lives in the hook, so there is no `make lint FILE=...` target to write).
