---
name: npm-private-registry
description: >-
  Install private scoped npm packages (@org/pkg) in a Turborepo + bun + Docker
  monorepo without leaking the token: root .npmrc with placeholder, BuildKit
  secret mount instead of ARG/ENV, compose build secrets. Use when adding a
  private package, configuring registry auth in Docker builds, or debugging 401
  / 404 errors during bun install in Docker.
tags:
  - ci-cd
  - docker
  - monorepo
  - npm
---

# NPM private registry — Turborepo + bun + Docker

Invariants live in `rules/04-tools-and-configurations/4-npm-private-registry.mdc`; this skill is the procedure.

## Token flow

```
.env (NPM_TOKEN)  ->  compose secret npm_token  ->  RUN --mount=type=secret  ->  .npmrc ${NPM_TOKEN}  ->  bun install
```

**Do not pass the token with `ARG` or `ENV`**: build args and env values are recorded in image metadata and visible in `docker history`, and `ENV NPM_TOKEN=` afterwards does not erase earlier layers. A secret mount exists only for the one `RUN` and is never written to a layer.

## Procedure

1. **`.npmrc` at the monorepo root** (`templates/.npmrc`): one scope = one `@scope:registry=` line, one auth line per registry, `${NPM_TOKEN}` placeholder, never a literal token. No `.npmrc` in sub-packages. It must not be in `.dockerignore`.
2. **Variable**: add `NPM_TOKEN=` (empty) to `.env.example`; the real value goes in the gitignored `.env`.
3. **Dockerfile** (`templates/Dockerfile.deps-stage`): `COPY .npmrc`, then `RUN --mount=type=secret,id=npm_token NPM_TOKEN="$(cat /run/secrets/npm_token)" bun install`. The runtime stage copies only `node_modules`.
4. **compose** (`templates/compose.snippet.yml`): `build.secrets` plus a top-level `secrets.npm_token.environment: NPM_TOKEN`. Build context is the monorepo root. Only services with private dependencies need it.
5. **Add the dependency** in the right `package.json`, then regenerate the lockfile in Docker (`docker compose up -d --build`), never on the host.

CI: `docker build --secret id=npm_token,env=NPM_TOKEN .`

Several registries: add one secret per token (`npm_token`, `github_token`) and set each variable in the same `RUN`.

## Local override of a private package

Mount the local checkout read-only and link it from the entrypoint:

```yaml
volumes:
  - ${PRIVATE_PKG_PATH:?}:/private-pkg:ro
```

```sh
if [ -f /private-pkg/package.json ]; then
  (cd /private-pkg && bun link) && bun link @acme/private-pkg
fi
```

## Debugging

- **401 Unauthorized**: token missing in `.env`; secret not listed under the service's `build.secrets`; `.npmrc` copied after `bun install`. Check the token with `npm whoami --registry=https://registry.npmjs.org/`.
- **404 Not Found**: scope line missing or wrong in `.npmrc`; package published on another registry.
- **Works on host, fails in Docker**: `.npmrc` in `.dockerignore`, or build context is not the monorepo root.
- **`secret not found`**: BuildKit disabled, or `NPM_TOKEN` not exported when compose reads `secrets.environment` (export it or use `--env-file`).

## Anti-patterns

- Literal token in `.npmrc` or a Dockerfile; token in `ARG`/`ENV`/`build.args`.
- `NPM_TOKEN` in runtime `environment` (install-only need).
- Per-package `.npmrc`; `bun install` on the host for private packages.
