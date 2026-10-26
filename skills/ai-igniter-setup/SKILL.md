---
name: ai-igniter-setup
description: >-
  Set up AI Igniter (ScreamZ/ai-igniter) in a project to manage isolated
  worktree-aware dev environments with automatic port allocation, managed .env
  sections, and Docker-based services (PostgreSQL, S3, custom). Use when
  onboarding a project for parallel-branch development or Claude Code worktrees.
tags:
  - devtools
  - worktree
  - docker
  - ports
  - environment
---

# AI Igniter Setup

## What AI Igniter Does

AI Igniter is a standalone Rust binary that solves three problems when running
multiple git worktrees (or branches) simultaneously:

1. **Port collisions** — two worktrees binding to the same port 3000, 5432, etc.
2. **Dirty .env files** — manual edits to DATABASE_URL and credentials per worktree.
3. **Service orchestration** — starting PostgreSQL, S3, Redis per worktree without
   bash scripts.

Each worktree gets its own Docker containers, its own port range, and a managed
section inside `.env` that AI Igniter owns.

## Prerequisites

Install the binary once per machine:

```bash
cargo install ai-igniter
```

Pre-built binaries for macOS (Intel/ARM), Linux (musl/glibc), and Windows are
available on the GitHub releases page:
https://github.com/ScreamZ/ai-igniter/releases

Verify:

```bash
ai-igniter --version
```

Docker must be running.

## When to Use This Skill

Use when asked to:
- Set up AI Igniter in a project
- Make a project worktree-ready (parallel branches, Claude Code sessions)
- Configure per-worktree isolated services (DB, cache, S3)
- Solve port conflicts in a multi-branch dev workflow

## Setup Procedure

### Step 1 — Detect the project stack

Read the project to identify:
- **Package manager and dev command** (e.g. `bun run dev`, `npm run dev`, `pnpm dev`, `make dev`)
- **Database** (PostgreSQL, MySQL, MongoDB) — look at docker-compose, .env, ORM config
- **Object storage** (S3, MinIO, Garage) — look at env vars, SDK imports
- **Other services** (Redis, Mailpit, Elasticsearch) — look at docker-compose, code imports
- **Existing .env file** — which variables exist, which reference localhost ports
- **Migration command** — look at package.json scripts, Makefile targets, ORM CLI
- **Seed command** — same sources

### Step 2 — Write `ai-igniter.toml`

Place the file at the project root. The file has four sections:

#### Minimal example (backend with PostgreSQL):

```toml
name = "my-project"
env_file = ".env"
dev_command = "bun run dev"

[services.postgres]
enabled = true
database = "my_project_dev"
user = "app"
password = "app"
migrate_command = "bun run db:migrate"
```

#### Full reference with all options:

```toml
# Project identity — used for container naming and port hashing
name = "my-project"

# Which .env file AI Igniter manages (it writes a fenced section inside it)
env_file = ".env"

# The dev command to run after services are healthy
dev_command = "bun run dev"

# Files to copy from the root checkout into each new worktree.
# Critical for Claude Code worktrees that need .env, certificates, etc.
copy_files = [".env", ".env.local", "certs/dev.pem"]

# ── PostgreSQL ──────────────────────────────────────────────
[services.postgres]
enabled = true
database = "my_project_dev"
user = "app"
password = "app"
version = "16"                          # Docker image tag, default "16"
migrate_command = "bun run db:migrate"  # Runs after DB is healthy
seed_command = "bun run db:seed"        # Runs after migration (optional)
extensions = ["pgcrypto", "uuid-ossp"]  # CREATE EXTENSION on startup

# E2E database — separate DB for integration tests
[services.postgres.e2e]
enabled = true
database = "my_project_test"
neon_proxy = true                       # Neon serverless proxy for branching

# ── Garage S3 ──────────────────────────────────────────────
[services.garage]
enabled = true
buckets = ["uploads", "exports"]
cors_origins = ["http://localhost:*"]
website_hosting = false

# ── Custom services (any Docker image) ──────────────────────
[[services.custom]]
name = "redis"
image = "redis:7-alpine"
ports = [6379]                          # Container port to expose
healthcheck = "redis-cli ping"
env = { REDIS_URL = "redis://localhost:${port}/0" }
volumes = ["redis-data:/data"]

[[services.custom]]
name = "mailpit"
image = "axllent/mailpit:latest"
ports = [1025, 8025]                    # SMTP + Web UI
env = { SMTP_HOST = "localhost", SMTP_PORT = "${port:1025}" }

# ── Orchestrator integration (optional) ─────────────────────
# Uncomment ONE block if using an orchestrator that manages port allocation.
# When set, AI Igniter reads the port base and env injection from the orchestrator
# instead of computing them itself.

# [orchestrator.paseo]
# config_file = "paseo.json"

# [orchestrator.conductor]
# port_env = "CONDUCTOR_PORT"
# root_env = "CONDUCTOR_ROOT"
```

### Step 3 — Configure worktree file copying

The `copy_files` array solves the problem of worktrees missing `.env` and other
non-tracked files. When `ai-igniter dev` runs in a worktree, it copies these
files from the root checkout if they are absent.

Typical candidates:
- `.env` and `.env.local` — credentials, API keys
- SSL certificates for local HTTPS
- `.npmrc` with registry tokens
- IDE-specific local configs

### Step 4 — Add to .gitignore

AI Igniter creates workspace-specific state. Add to `.gitignore`:

```gitignore
# AI Igniter workspace state
.ai-igniter/
```

The `ai-igniter.toml` config file itself **should be committed** — it is the
shared team configuration.

### Step 5 — Wire .env variables

AI Igniter writes a managed section into the `.env` file between fences:

```
# ── AI Igniter managed (do not edit) ──
DATABASE_URL=postgresql://app:app@localhost:15432/my_project_dev
POSTGRES_PORT=15432
S3_ENDPOINT=http://localhost:13900
S3_ACCESS_KEY=...
S3_SECRET_KEY=...
REDIS_URL=redis://localhost:16379/0
# ── end AI Igniter ──
```

The application code reads these variables from `.env` as usual.
AI Igniter never touches lines outside its fenced section.

Check that the application's existing .env variable names match what AI Igniter
will inject. If names differ, use the `env` table in custom services or the
template syntax to map them:

```toml
[[services.custom]]
name = "redis"
image = "redis:7-alpine"
ports = [6379]
env = { CACHE_REDIS_URL = "redis://localhost:${port}/0" }
```

### Step 6 — Test the setup

```bash
ai-igniter dev
```

This command:
1. Resolves a free port range for this workspace
2. Starts Docker containers for each enabled service
3. Waits for health checks
4. Runs migrations and seeds
5. Writes the managed .env section
6. Starts the dev command

To inspect without starting:

```bash
ai-igniter status    # Show port assignments and container health
ai-igniter env       # Print the environment variables that would be written
```

To tear down:

```bash
ai-igniter teardown  # Stop and remove containers + volumes for this workspace
```

## Port Allocation

AI Igniter assigns ports deterministically from the workspace path hash.
Each service gets an offset from a base port:

| Service     | Offset |
|-------------|--------|
| PostgreSQL  | +0     |
| Garage API  | +1     |
| Garage Web  | +2     |
| Custom [0]  | +3     |
| Custom [1]  | +4     |

The base port differs per worktree because the hash differs.
Two worktrees of the same repo get non-overlapping port ranges.

To force a specific base port:

```bash
ai-igniter dev --port 20000
```

## Commands Reference

| Command                      | Effect                                    |
|------------------------------|-------------------------------------------|
| `ai-igniter init`           | Interactive setup wizard                   |
| `ai-igniter dev`            | Start services + migrations + dev command  |
| `ai-igniter dev --reset`    | Full reset: wipe volumes, re-create        |
| `ai-igniter dev --no-command`| Services only, skip the dev command        |
| `ai-igniter teardown`       | Stop and remove containers                 |
| `ai-igniter status`         | Port and health inspection                 |
| `ai-igniter env`            | Print computed env vars                    |
| `ai-igniter env --write`    | Write env vars to .env without starting    |
| `ai-igniter update`         | Check for binary updates                   |

## Integration with Claude Code Worktrees

Claude Code creates worktrees under `.claude/worktrees/`. These worktrees share
the git stash stack but not the working tree — so `.env` and other untracked
files are absent.

AI Igniter solves this with `copy_files`: on first `ai-igniter dev`, it copies
the listed files from the root checkout into the worktree. Combined with
per-worktree port allocation, each Claude Code session gets an isolated
environment without conflicts.

Recommended `copy_files` for a typical project:

```toml
copy_files = [
  ".env",
  ".env.local",
  ".env.development.local",
]
```

## Adapting to Existing Docker Compose Projects

If the project already has a `docker-compose.yml`:

1. Identify which services AI Igniter should manage (typically DB + cache).
2. Remove those services from docker-compose.yml or keep them for CI only.
3. Configure AI Igniter to provide those services with isolated ports.
4. The dev command in `ai-igniter.toml` can still be `docker compose up` for
   the remaining application services.

AI Igniter and Docker Compose can coexist: AI Igniter manages infrastructure
services with port isolation, Docker Compose manages application containers.

## Checklist

After setup, verify:

- [ ] `ai-igniter.toml` committed to the repo
- [ ] `.ai-igniter/` in `.gitignore`
- [ ] `copy_files` lists every untracked file a worktree needs
- [ ] `ai-igniter dev` starts services, runs migrations, launches the app
- [ ] `ai-igniter status` shows healthy services
- [ ] A second worktree runs `ai-igniter dev` without port conflicts
- [ ] The application reads the managed .env variables correctly

## Implementation Status

**Fully Implemented** — This skill covers the complete AI Igniter setup
workflow. The config reference tracks AI Igniter v0.x (current stable).
