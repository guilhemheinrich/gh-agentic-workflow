---
description: >-
  Templates and procedures for a project-root Makefile: env vars, targets up,
  down, test, setup, db-*, coverage. Use when authoring or debugging Makefiles.
tags:
  - docker
  - make
  - monorepo
---

# Makefile conventions — templates and procedures

## Context

Use this skill when implementing the **concrete** recipes and copy-paste templates for a root `Makefile`. The **declarative invariants** (what targets must exist, naming) live in the rule `rules/00-architecture/0-makefile-structure.mdc`.

## Environment variables

All configurable values (ports, service URLs, images, and so on) SHOULD be read from `.env` with fallbacks consistent with `.env.example`.

```makefile
include .env
export

# Application URLs (derived from PORT variables from .env)
APP_URL ?= http://localhost:$(APP_PORT)
ADMIN_URL ?= http://localhost:$(ADMIN_PORT)
API_URL ?= http://localhost:$(API_PORT)
DB_STUDIO_URL ?= http://localhost:$(DB_STUDIO_PORT)
REDIS_URL ?= redis://localhost:$(REDIS_PORT)
PROMETHEUS_URL ?= http://localhost:$(PROMETHEUS_PORT)
GRAFANA_URL ?= http://localhost:$(GRAFANA_PORT)
PGADMIN_URL ?= http://localhost:$(PGADMIN_PORT)
SENTRY_URL ?= http://localhost:$(SENTRY_PORT)
KIBANA_URL ?= http://localhost:$(KIBANA_PORT)

# Fallback .env.example values (if .env is missing)
APP_PORT ?= 3000
ADMIN_PORT ?= 3001
API_PORT ?= 8080
DB_STUDIO_PORT ?= 5555
REDIS_PORT ?= 6379
PROMETHEUS_PORT ?= 9090
GRAFANA_PORT ?= 3000
PGADMIN_PORT ?= 5050
SENTRY_PORT ?= 8000
KIBANA_PORT ?= 5601
```

## Target: `up` — start the stack (example)

```makefile
up:
	docker compose up -d --build
	@echo ""
	@echo "Services started."
	@echo "App:     $(APP_URL)"
	@echo "API:     $(API_URL)"
	@echo "To stop: make down"
```

## Target: `down`

```makefile
down:
	docker compose down
```

## Target: `test` — full suite (monorepo)

```makefile
test: test-unit test-integration test-e2e

test-unit:
	docker compose exec <service> npm run test:unit

test-integration:
	docker compose exec <service> npm run test:integration

test-e2e:
	docker compose exec <service> npm run test:e2e
```

Repeat `docker compose exec` lines per app/package in a monorepo; for a single package, collapse to one service.

## Target: `coverage`

```makefile
coverage:
	docker compose exec <service-1> npm run test:coverage
	docker compose exec <service-2> npm run test:coverage
```

## Target: `setup` — idempotent init

```makefile
setup:
	cp -n .env.example .env || true
	docker compose build
	$(MAKE) db-migrate
```

## Target: `db-*`

```makefile
db-migrate:
	docker compose exec <service> npx prisma migrate deploy

db-reset:
	docker compose exec <service> npx prisma migrate reset --force

db-seed:
	docker compose exec <service> npx prisma db seed

db-studio:
	docker compose exec <service> npx prisma studio
```

Adapt to your ORM (Drizzle, TypeORM, Alembic, and so on).

## PHONY

```makefile
.PHONY: up down setup test test-unit test-integration test-e2e coverage db-migrate db-reset db-seed db-studio
```

## Rules of thumb

- Prefer executing test and install commands **inside** containers, not on the host, when the project uses Docker for dev.
- Keep token and secret values out of the Makefile; use environment variables from `.env`.
