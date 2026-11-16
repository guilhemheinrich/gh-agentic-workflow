---
name: dockerfile
description: >-
  Write Dockerfiles with named dev and prod stages instead of build args, and
  generate the lockfile inside Docker with make lock / task lock. Covers the
  monorepo turbo prune pattern with bun, development vs production targets,
  frozen-lockfile installs and lockfile troubleshooting. Use when creating or
  reviewing a Dockerfile, configuring dev vs production builds, regenerating a
  lockfile, or debugging "lockfile had changes, but lockfile is frozen".
tags:
  - docker
  - ci-cd
  - monorepo
---

# Dockerfile — dev / prod stages and lockfile strategy

Two dependency modes, selected by **named stages** (`--target`), never by `ARG`.

| Stage | Install | Selected by |
|:---|:---|:---|
| `development` (+ `development-runtime` in monorepos) | Free install, no lockfile input. The lockfile is a **product** of this stage. | compose `target:` (always) |
| `production` (+ `production-runtime`) | Frozen install (`--frozen-lockfile`, `npm ci`, ...) from the committed lockfile. | infra/CI: `docker build --target production` |

## Rules

- Never `--frozen-lockfile` in the development stage; never copy a lockfile there.
- The lockfile is always committed; production depends on it.
- Never generate it with an ephemeral `docker run --rm` (it runs the entrypoint: migrations, seed).
- compose always targets the development stage, with no `${TARGET}` variable. Production is never built through compose.
- Dev `CMD` is watch mode (`dev`); prod `CMD` is the built start (`start`).
- Pin base image tags (`oven/bun:1.3-alpine`); run production as non-root (`USER`).

## Single package

`templates/Dockerfile.simple`. Lockfile extraction: `templates/Taskfile.lock.yml`, or the same steps in a Makefile `lock` target (`docker compose build`, `up -d`, `cp <svc>:/app/<lockfile> ./<lockfile>`, `down`; never forget `down`). Per ecosystem only the commands change:

| Ecosystem | Dev install | Prod install | Lockfile |
|:---|:---|:---|:---|
| bun | `bun install` | `bun install --frozen-lockfile` | `bun.lock` |
| npm | `npm install` | `npm ci` | `package-lock.json` |
| pnpm (`corepack enable`) | `pnpm install --no-frozen-lockfile` | `pnpm install --frozen-lockfile` | `pnpm-lock.yaml` |
| pip-tools | `pip-compile requirements.in -o requirements.txt && pip install -r requirements.txt` | `pip install -r requirements.txt` | `requirements.txt` |
| composer | `composer install` | `composer install --no-dev --no-scripts --prefer-dist` | `composer.lock` |

## Monorepo with turbo prune (bun)

`templates/Dockerfile.turbo`; lockfile extraction `templates/Makefile.lock`.

- **Never feed turbo's pruned lockfile to `--frozen-lockfile`**: it is incomplete or corrupted for bun, and the full monorepo lockfile references packages absent from the pruned subset. The valid lockfile is the one `bun install` produces in the `development` stage.
- `development-runtime` copies it to `/app/bun.lock.docker`; `make lock-<app>` extracts it to `apps/<app>/bun.lock.docker` (committed); `production` copies it back as `bun.lock`.
- `docker create` + `docker cp`, not `docker compose cp`: no running container is needed and the entrypoint never runs.

Workflow: edit `package.json`, `docker compose up -d --build <app>`, `make lock-<app>`, commit the lockfile; CI builds `--target production-runtime`.

## Troubleshooting

- `lockfile had changes, but lockfile is frozen` (production): stale lockfile; run `make lock-<app>` and commit.
- `Cannot find package '@scope/pkg'` at runtime: stale anonymous `node_modules` volume. `docker compose down <svc> && docker compose up -d --build <svc>`.
- `docker compose restart` does not re-read `.env`; use `docker compose up -d <svc>` to recreate.

## Related

- `docker-hotreload-volume`: hot reload with an isolated `node_modules`.
- `npm-private-registry`: private scopes at install time.
