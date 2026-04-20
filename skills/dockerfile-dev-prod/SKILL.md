---
name: dockerfile-dev-prod
description: "Write Dockerfiles with a DEVELOPMENT build argument for dual-mode dependency installation. Use when creating a Dockerfile, configuring dev vs production builds, handling lockfile generation via make copy-vendor, or debugging dependency install issues in Docker."
---

# Dockerfile — Development / Production Mode

Universal pattern for writing Dockerfiles that support two dependency installation modes via a `DEVELOPMENT` build argument.

## Core Principle

| Mode | `DEVELOPMENT` | Behavior |
|:---|:---|:---|
| Production | undefined | Install via strict lockfile (`--frozen-lockfile`, `--ci`, etc.) — fails if lockfile is missing or out of sync. |
| Development | defined (e.g., `1`) | Install without lockfile — the package manager resolves dependencies and **generates/updates the lockfile in the container**. |

## Essential Rule

> **Never launch an ephemeral container (`docker run --rm …`) to generate the lockfile.**
>
> The lockfile is produced as a side-effect of the build in DEVELOPMENT mode, then retrieved via `make copy-vendor`.

## Dockerfile Pattern (multi-stage)

```dockerfile
FROM <base-image> AS deps

ARG DEVELOPMENT

WORKDIR /app

COPY package.json ./
# Copy the lockfile only if it exists (for prod mode)
COPY <lockfile>* ./

# Dev mode   → free resolution (generates/updates lockfile)
# Prod mode → strict installation via lockfile
RUN if [ -n "$DEVELOPMENT" ]; then \
       <pkg-manager> install; \
    else \
       <pkg-manager> install --frozen-lockfile; \
    fi
```

### Ecosystem Examples

**Node.js (bun)**

```dockerfile
ARG DEVELOPMENT
COPY package.json ./
COPY bun.lock* ./

RUN if [ -n "$DEVELOPMENT" ]; then \
      bun install; \
    else \
      bun install --frozen-lockfile; \
    fi
```

**Node.js (npm)**

```dockerfile
ARG DEVELOPMENT
COPY package.json ./
COPY package-lock.json* ./

RUN if [ -n "$DEVELOPMENT" ]; then \
      npm install; \
    else \
      npm ci; \
    fi
```

**Node.js (pnpm)**

```dockerfile
ARG DEVELOPMENT
COPY package.json ./
COPY pnpm-lock.yaml* ./

RUN if [ -n "$DEVELOPMENT" ]; then \
      pnpm install --no-frozen-lockfile; \
    else \
      pnpm install --frozen-lockfile; \
    fi
```

**Python (pip)**

```dockerfile
ARG DEVELOPMENT
COPY requirements.in ./
COPY requirements.txt* ./

RUN if [ -n "$DEVELOPMENT" ]; then \
      pip-compile requirements.in -o requirements.txt && \
      pip install -r requirements.txt; \
    else \
      pip install -r requirements.txt; \
    fi
```

**PHP (composer)**

```dockerfile
ARG DEVELOPMENT
COPY composer.json ./
COPY composer.lock* ./

RUN if [ -n "$DEVELOPMENT" ]; then \
      composer install; \
    else \
      composer install --no-dev --no-scripts --prefer-dist; \
    fi
```

## compose.yaml

```yaml
services:
  my-service:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        DEVELOPMENT: ${DEVELOPMENT:-}
```

- `DEVELOPMENT` is passed only if defined in `.env` or shell environment.
- In CI/production: do not define `DEVELOPMENT` → strict build.

## Makefile — `copy-vendor`

The `make copy-vendor` command copies the lockfile **from the container already running** to the host.

```makefile
SERVICE_NAME := my-service

copy-vendor:
	docker compose cp $(SERVICE_NAME):/app/<lockfile> ./<lockfile>
```

### Examples

```makefile
# Node.js (bun)
copy-vendor:
	docker compose cp frontend:/app/bun.lock ./bun.lock

# Node.js (npm)
copy-vendor:
	docker compose cp frontend:/app/package-lock.json ./package-lock.json

# Python
copy-vendor:
	docker compose cp api:/app/requirements.txt ./requirements.txt

# PHP
copy-vendor:
	docker compose cp api:/app/composer.lock ./composer.lock
```

### Updated Makefile — Use `make lock` for Dependencies

Instead of `make copy-vendor`, use `make lock` when updating dependencies. This command generates and copies all lockfiles in one step:

```makefile
lock:
	# Build container in dev mode to generate lockfile
	DEVELOPMENT=1 docker compose build my-service
	
	# Copy all lockfiles from container to host
	<package-manager> lock
	
	# Commit lockfile changes
	git add <lockfile>
	git commit -m "chore: update lockfile"
```

**IMPORTANT**: Always run `make lock` before pushing or updating any dependencies:
```bash
# 1. Install/update package globally
npm install package-name

# 2. Generate lockfile via make lock
make lock

# 3. Verify changes
git status

# 4. Push to remote (lockfile is ready!)
git push origin feature-branch
```

This pattern ensures:
- Lockfiles are always up-to-date before commits
- No manual lockfile copying needed
- Consistent dependency resolution across environments

## Complete Workflow (Traditional)

```bash
# 1. Build in dev mode (generates lockfile in container)
DEVELOPMENT=1 docker compose build my-service

# 2. Start the service
docker compose up -d

# 3. Retrieve lockfile on host
make copy-vendor

# 4. Commit the lockfile
git add <lockfile>
git commit -m "chore: update lockfile"
```

## Checklist

```
[ ] Dockerfile: ARG DEVELOPMENT declared
[ ] Dockerfile: Conditional branch (if/else) on $DEVELOPMENT
[ ] Dockerfile: lockfile is COPY with glob (*) to avoid failure if missing
[ ] compose.yaml: DEVELOPMENT passed via build.args
[ ] Makefile: copy-vendor target using docker compose cp
[ ] Lockfile is committed in repo
[ ] No ephemeral docker run for lockfile generation
[ ] NEW: Use `make lock` instead of manual copy-vendor for dependency updates
```

## Anti-patterns

- Running `docker run --rm <image> cat <lockfile> > <lockfile>` to extract lockfile → use `docker compose cp` on existing container
- Installing dependencies without lockfile in production → always use `--frozen-lockfile` / `--ci`
- Not committing lockfile → it's part of the source code
- Hardcoding the mode in Dockerfile instead of `ARG DEVELOPMENT`
- Using `COPY <lockfile> ./` without glob in dev mode → build fails if file doesn't exist yet
- Using `make copy-vendor` instead of `make lock` for dependency updates → always run `make lock` before pushing dependencies
