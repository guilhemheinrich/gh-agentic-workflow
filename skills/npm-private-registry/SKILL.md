---
name: npm-private-registry
description: "Integrate private npm packages in a Turborepo + bun + Docker monorepo. Use when adding a scoped private package (@org/pkg), configuring registry auth in Docker builds, or debugging NPM_TOKEN issues. Covers .npmrc, Dockerfile multi-stage, compose build args, and security cleanup."
---

# NPM Private Registry — Turborepo + Bun + Docker

This skill documents the complete procedure for integrating a private npm package (scoped) in a Turborepo + bun monorepo with Docker multi-stage builds.

## When to Use This Skill

- Adding a new private npm package (e.g., `@septeo-immo/calendar-wc`)
- Initial configuration of private registry access
- Debugging `401 Unauthorized` or `404 Not Found` errors during `bun install` in Docker
- Adding a new private npm scope (e.g., `@other-org/...`)
- Migrating from a local package (volume mount) to a package published on a registry

## Prerequisites

- A valid npm token with read access to the private scope
- The token must be in `.env` (never committed)

## Authentication Flow Architecture

```
.env (NPM_TOKEN=npm_xxxx)
    │
    ▼
compose.yaml ─── build.args.NPM_TOKEN: ${NPM_TOKEN:-}
    │
    ▼
Dockerfile ────── ARG NPM_TOKEN
                  ENV NPM_TOKEN=${NPM_TOKEN}
    │
    ▼
.npmrc ────────── //registry.npmjs.org/:_authToken=${NPM_TOKEN}
    │
    ▼
bun install ───── Authentication successful
    │
    ▼
Cleanup ───────── RUN rm -f .npmrc
                  ENV NPM_TOKEN=
```

## Step-by-Step Procedure

### Step 1 — Configure `.npmrc` at the monorepo root

The `.npmrc` is **unique and at the root** of the monorepo. Bun reads it automatically.

```ini
# .npmrc (monorepo root)
@septeo-immo:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

**Rules:**
- One scope = one `@scope:registry=...` line
- One auth line per registry `//registry.url/:_authToken=...`
- Use `${NPM_TOKEN}` (env interpolation), never a hardcoded token
- **No `.npmrc` in sub-packages** (`apps/`, `packages/`) — only at the root

To add a second private scope on a different registry:

```ini
# .npmrc
@septeo-immo:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN}

@other-org:registry=https://npm.pkg.github.com/
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

### Step 2 — Declare `NPM_TOKEN` in `.env.example`

```bash
# .env.example
# ─── NPM Private Registry ───────────────────────────────────
NPM_TOKEN=
```

And in `.env` (not committed):

```bash
NPM_TOKEN=npm_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Step 3 — Configure the Dockerfile (multi-stage)

The critical pattern: the token exists only in the build stage, then is removed.

```dockerfile
# Stage 1 — Dependency installation with auth
FROM oven/bun:1.3-alpine AS deps

# ── Private registry token ──
ARG NPM_TOKEN
ENV NPM_TOKEN=${NPM_TOKEN}

WORKDIR /app

# ── Copy files needed for dependency resolution ──
COPY package.json bun.lock* turbo.json ./
COPY apps/<service>/package.json apps/<service>/
# If other monorepo packages are dependencies:
# COPY packages/shared/package.json packages/shared/
COPY .npmrc .npmrc

# ── Install ──
RUN bun install --frozen-lockfile 2>/dev/null || bun install

# ── SECURITY: remove token and .npmrc ──
RUN rm -f .npmrc
ENV NPM_TOKEN=

# Stage 2 — Runtime (no token, no .npmrc)
FROM node:22-alpine
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY apps/<service>/ .
# ... rest of runtime config
```

**Critical points:**
- `ARG NPM_TOKEN` + `ENV NPM_TOKEN=${NPM_TOKEN}`: makes token available for `.npmrc`
- `COPY .npmrc .npmrc`: copied **before** `bun install`
- `RUN rm -f .npmrc` + `ENV NPM_TOKEN=`: cleanup **after** `bun install`
- Stage 2 (`FROM node:22-alpine`) contains neither the token nor `.npmrc`

### Step 4 — Pass the token via `compose.yaml`

```yaml
services:
  frontend:
    build:
      context: .
      dockerfile: .docker/frontend/Dockerfile
      args:
        NPM_TOKEN: ${NPM_TOKEN:-}
```

**Rules:**
- `${NPM_TOKEN:-}`: empty default value (no error if absent)
- `context: .` must be the monorepo root (to access `.npmrc`)
- Only services that depend on private packages need `build.args`

### Step 5 — Add the dependency in the appropriate `package.json`

```json
{
  "dependencies": {
    "@septeo-immo/calendar-wc": "*"
  }
}
```

Then regenerate the lockfile:

```bash
# Via Docker (NEVER on the host)
docker compose exec <service> bun install
# Or full rebuild
docker compose up -d --build
```

## Integration Checklist for a New Private Package

```
[ ] .npmrc: scope + auth configured at root
[ ] .env.example: token variable(s) documented
[ ] .env: token filled in (not committed)
[ ] Dockerfile for the service: ARG/ENV NPM_TOKEN, COPY .npmrc, post-install cleanup
[ ] compose.yaml: build.args.NPM_TOKEN passed to the service
[ ] package.json: dependency added in the correct app/package
[ ] .dockerignore: .npmrc is NOT in .dockerignore (needed for build)
[ ] .gitignore: .env is ignored (token must never be committed)
[ ] Test: docker compose up -d --build succeeds
```

## Security

### What is committed (safe)

| File | Sensitive content? | Why it's safe |
|------|--------------------|---------------|
| `.npmrc` | No | Contains `${NPM_TOKEN}`, not the actual token |
| `.env.example` | No | Empty value `NPM_TOKEN=` |
| `Dockerfile` | No | `ARG NPM_TOKEN` with no default value |
| `compose.yaml` | No | `${NPM_TOKEN:-}` references `.env` |

### What is NEVER committed

| File | Content | Protection |
|------|---------|------------|
| `.env` | `NPM_TOKEN=npm_xxxx` | `.gitignore` |

### Protection in the Docker Image

- Token exists only in the `deps` stage (stage 1)
- `RUN rm -f .npmrc` removes the config file
- `ENV NPM_TOKEN=` overwrites the environment variable
- Stage 2 (`FROM node:22-alpine`) starts from a clean image
- Only `node_modules` is copied from stage 1 to stage 2

## Edge Cases

### Service without private dependency (e.g., backend)

No need for `ARG NPM_TOKEN` or `COPY .npmrc` in the Dockerfile:

```dockerfile
FROM oven/bun:1.3-alpine AS deps
WORKDIR /app
COPY package.json bun.lock* turbo.json ./
COPY apps/backend/package.json apps/backend/
COPY packages/shared/package.json packages/shared/
# No COPY .npmrc, no ARG NPM_TOKEN
RUN bun install --frozen-lockfile 2>/dev/null || bun install
```

### Local dev with volume mount (package override)

To use a local version of a private package during development:

```yaml
# compose.yaml
volumes:
  - ${CALENDAR_WC_PATH:-../calendar-wc}:/calendar-wc:ro
```

```sh
# entrypoint.sh
if [ -d "/calendar-wc" ] && [ -f "/calendar-wc/package.json" ]; then
  cd /calendar-wc && bun link 2>/dev/null || true
  cd /app && bun link @septeo-immo/calendar-wc 2>/dev/null || true
fi
```

### Multiple tokens for multiple registries

```ini
# .npmrc
@septeo-immo:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN}

@github-org:registry=https://npm.pkg.github.com/
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

```yaml
# compose.yaml
build:
  args:
    NPM_TOKEN: ${NPM_TOKEN:-}
    GITHUB_TOKEN: ${GITHUB_TOKEN:-}
```

```dockerfile
ARG NPM_TOKEN
ARG GITHUB_TOKEN
ENV NPM_TOKEN=${NPM_TOKEN}
ENV GITHUB_TOKEN=${GITHUB_TOKEN}
# ... bun install ...
RUN rm -f .npmrc
ENV NPM_TOKEN=
ENV GITHUB_TOKEN=
```

## Debugging

### `401 Unauthorized` error during `bun install`

1. Verify `NPM_TOKEN` is in `.env`
2. Verify `compose.yaml` passes `args.NPM_TOKEN`
3. Verify the Dockerfile has `ARG NPM_TOKEN` + `ENV NPM_TOKEN`
4. Verify `.npmrc` is copied **before** `bun install`
5. Test the token: `npm whoami --registry=https://registry.npmjs.org/`

### `404 Not Found` for a scoped package

1. Verify the scope in `.npmrc`: `@scope:registry=...`
2. Verify the package name matches the scope (e.g., `@septeo-immo/calendar-wc`)
3. Verify the package is published on the correct registry

### `bun install` works locally but not in Docker

1. Verify `.npmrc` is not in `.dockerignore`
2. Verify `COPY` order: `.npmrc` must be copied before `RUN bun install`
3. Verify the build `context` is the monorepo root (to access `.npmrc`)

## Anti-patterns

- Hardcoding the token in `.npmrc` or the Dockerfile
- Leaving `.npmrc` or `NPM_TOKEN` in the final image
- Creating `.npmrc` per sub-package instead of a single one at the root
- Passing `NPM_TOKEN` in `environment` instead of `build.args` (unnecessary at runtime)
- Adding `.npmrc` to `.dockerignore` (blocks the build)
- Running `bun install` on the host to resolve private packages
