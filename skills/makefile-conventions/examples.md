# Makefile — exemples réels

## Exemple 1 : Monorepo NestJS + Temporal (DevTalk)

Stack : NestJS API, Worker Temporal, Admin UI, PostgreSQL, MinIO, Temporal.
Package manager : pnpm (dans le conteneur).

```makefile
COMPOSE = docker compose
RUN_API = $(COMPOSE) run --rm api
RUN_WORKER = $(COMPOSE) run --rm worker
COMPOSE_EXEC_API = $(COMPOSE) exec api

# ──── URLs (derived from .env with fallbacks) ──────────────────
-include .env
export

API_PORT     ?= 3000
ADMIN_PORT   ?= 3001
MINIO_CONSOLE_PORT ?= 9001
TEMPORAL_UI_PORT ?= 8080

API_URL           ?= http://localhost:$(API_PORT)
ADMIN_URL         ?= http://localhost:$(ADMIN_PORT)
OPENAPI_URL       ?= $(API_URL)/api
API_JSON_URL      ?= $(API_URL)/api-json
HEALTH_URL        ?= $(API_URL)/health
MINIO_URL         ?= http://localhost:$(MINIO_CONSOLE_PORT)
TEMPORAL_UI_URL   ?= http://localhost:$(TEMPORAL_UI_PORT)

# ──── Helpers ──────────────────────────────────────────────────
BOLD  = \033[1m
CYAN  = \033[36m
GREEN = \033[32m
YELLOW = \033[33m
RESET = \033[0m
LINE  = \033[90m──────────────────────────────────────────────────\033[0m

define print_resource
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "$(1)" "$(2)"
endef

.PHONY: help up down logs test lint typecheck copy-vendors locks clean

help: ## Show available targets
	@printf "\n$(BOLD)DevTalk — available targets$(RESET)\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@printf "\n"

# ──── Lifecycle ────────────────────────────────────────────────

up: ## Start all services and print exposed resources
	@printf "\n$(BOLD)Starting services...$(RESET)\n"
	@$(COMPOSE) up -d
	@printf "\n$(LINE)\n"
	@printf "$(BOLD)$(GREEN)  Stack is up$(RESET)\n"
	@printf "$(LINE)\n"
	$(call print_resource,API (REST),$(API_URL))
	$(call print_resource,Swagger UI,$(OPENAPI_URL))
	$(call print_resource,OpenAPI JSON,$(API_JSON_URL))
	$(call print_resource,Health check,$(HEALTH_URL))
	$(call print_resource,MinIO console,$(MINIO_URL))
	$(call print_resource,Temporal UI,$(TEMPORAL_UI_URL))
	$(call print_resource,Admin UI,$(ADMIN_URL))
	@printf "$(LINE)\n"
	@printf "  $(YELLOW)Logs$(RESET)  make logs     $(YELLOW)Stop$(RESET)  make down\n\n"

down: ## Stop all services
	@printf "\n$(BOLD)Stopping services...$(RESET)\n"
	@$(COMPOSE) down
	@printf "$(GREEN)  All services stopped.$(RESET)\n\n"

# ──── Quality ──────────────────────────────────────────────────

test: ## Run all tests via Docker
	@printf "\n$(BOLD)Running tests...$(RESET)\n"
	@printf "  $(CYAN)[api]$(RESET)\n"
	$(RUN_API) pnpm run test
	@printf "  $(CYAN)[worker]$(RESET)\n"
	$(RUN_WORKER) pnpm run test
	@printf "$(GREEN)  All tests passed.$(RESET)\n\n"

lint: ## Run linter via Docker
	@printf "\n$(BOLD)Linting...$(RESET)\n"
	$(RUN_API) pnpm run lint
	$(RUN_WORKER) pnpm run lint

typecheck: ## Run type checker via Docker
	@printf "\n$(BOLD)Type-checking...$(RESET)\n"
	$(RUN_API) pnpm run typecheck
	$(RUN_WORKER) pnpm run typecheck

# ──── Sync ────────────────────────────────────────────────────

copy-vendors: ## Copy node_modules from containers to host (IDE linting)
	@printf "\n$(BOLD)Syncing node_modules to host...$(RESET)\n"
	$(COMPOSE) cp api:/app/node_modules ./node_modules
	$(COMPOSE) cp api:/app/apps/api/node_modules ./apps/api/node_modules
	$(COMPOSE) cp worker:/app/apps/worker/node_modules ./apps/worker/node_modules
	@printf "$(GREEN)  node_modules synced. Your IDE linter should now resolve deps.$(RESET)\n\n"

locks: ## Copy pnpm-lock.yaml from container to host (CI)
	@printf "\n$(BOLD)Exporting lockfile from container...$(RESET)\n"
	$(COMPOSE) cp api:/app/pnpm-lock.yaml ./pnpm-lock.yaml
	@printf "$(GREEN)  pnpm-lock.yaml updated.$(RESET)\n\n"
```

### Points clés de cet exemple

- **`print_resource`** : macro réutilisable pour afficher chaque URL de manière alignée.
- **Fallbacks cohérents** : chaque port a un `?=` qui correspond au `.env.example`.
- **`copy-vendors`** copie chaque workspace séparément (monorepo turborepo/pnpm).
- **`locks`** extrait le lockfile depuis le conteneur (le lockfile est généré au build).

---

## Exemple 2 : Monorepo NestJS + Nuxt + E2E (modelo-calendar)

Stack : NestJS Backend, Nuxt Frontend, PostgreSQL, BullMQ, Playwright E2E.
Package manager : bun (dans le conteneur).

```makefile
COMPOSE = docker compose
EXEC    = $(COMPOSE) exec -T backend

# Optional: TAGS=tag1,tag2 → Playwright --grep "@tag1|@tag2"
PW_GREP := $(if $(TAGS),--grep "$(shell echo '$(TAGS)' | sed 's/,/|@/g' | sed 's/^/@/')",)

.PHONY: help up down destroy test test-e2e copy-vendors copy-lock lock
.DEFAULT_GOAL := help

# ─── Lifecycle ────────────────────────────────────────────────

up: ## Start the environment (build + start + seed + sync lockfile)
	$(COMPOSE) up -d --build --remove-orphans
	@echo "⏳ Waiting for backend to be ready..."
	@for i in $$(seq 1 20); do \
		$(COMPOSE) exec -T backend sh -c \
			'wget -qO /dev/null http://localhost:$${PORT:-3100}/api/v1/health 2>/dev/null' \
			&& break; \
		sleep 2; \
	done
	@echo "🌱 Seeding database..."
	@$(EXEC) bun x prisma db seed 2>&1 || echo "⚠️  Seed skipped"
	@echo "🔒 Syncing lockfile to host..."
	@$(MAKE) --no-print-directory copy-lock
	@echo ""
	@echo "✔ Environnement prêt."
	@echo "  → Backend  : http://localhost:$${APP_PORT_BACKEND:-3100}/api/docs"
	@echo "  → Frontend : http://localhost:$${APP_PORT_FRONTEND:-3101}"
	@echo "  → BullBoard: http://localhost:$${APP_PORT_BACKEND:-3100}/admin/queues"
	@echo "  → DbGate   : http://localhost:$${DBGATE_PORT:-3200}"
	@echo "  → Mailpit  : http://localhost:$${MAILER_PORT_UI:-8025}"

down: ## Stop all services
	$(COMPOSE) down

destroy: ## Stop and remove volumes (full reset)
	$(COMPOSE) down -v --remove-orphans

# ─── Tests ───────────────────────────────────────────────────

test: ## Run backend tests
	$(EXEC) bun x jest

test-e2e: ## Run E2E tests (Playwright). Optional: TAGS=tag1,tag2
	$(COMPOSE) -f compose.yml -f compose.e2e.yml --profile e2e up -d --build
	@echo "⏳ Waiting for backend (standalone mode)..."
	@for i in $$(seq 1 15); do \
		$(COMPOSE) -f compose.yml -f compose.e2e.yml exec -T backend \
			sh -c 'wget -qO /dev/null http://localhost:$${PORT:-3100}/api/v1/health 2>/dev/null' \
			&& break; \
		sleep 2; \
	done
	@echo "🗄️  Cleaning E2E test data..."
	@$(COMPOSE) -f compose.yml -f compose.e2e.yml exec -T backend \
		bun run prisma/e2e-cleanup.ts 2>&1 || (echo "❌ Cleanup failed" && exit 1)
	@e2e_exit=0; \
	$(COMPOSE) -f compose.yml -f compose.e2e.yml --profile e2e \
		run --rm playwright npx playwright test $(PW_GREP) || e2e_exit=$$?; \
	echo "📋 Copying Playwright report..."; \
	rm -rf playwright-report && \
		cp -r apps/e2e/playwright-report playwright-report 2>/dev/null || \
		echo "⚠️  No report found."; \
	echo "🔄 Restoring backend..."; \
	$(COMPOSE) up -d backend --build; \
	echo ""; \
	echo "📊 E2E report: playwright-report/index.html"; \
	echo "   Open with: open playwright-report/index.html"; \
	exit $$e2e_exit

# ─── Sync ────────────────────────────────────────────────────

copy-vendors: ## Copy node_modules from containers to host (IDE)
	@echo "🧹 Cleaning stale host node_modules..."
	rm -rf ./apps/backend/node_modules
	$(COMPOSE) cp backend:/app/node_modules ./apps/backend/
	@echo "✔ Backend node_modules copied."
	rm -rf ./apps/frontend/node_modules
	$(COMPOSE) cp frontend:/app/node_modules ./apps/frontend/
	@echo "✔ Frontend node_modules copied."
	rm -rf ./node_modules
	$(COMPOSE) cp backend:/app/node_modules ./node_modules
	@echo "✔ Workspace node_modules copied."
	@$(MAKE) --no-print-directory copy-lock

copy-lock: ## Copy lockfiles from containers to host
	@$(COMPOSE) cp backend:/build-lock/bun.lock ./bun.lock 2>/dev/null \
		&& echo "✔ bun.lock copied." \
		|| echo "⚠️  bun.lock not found (rebuild with make up)."

lock: ## Regenerate lockfiles (rebuild + copy)
	@echo "🔒 Rebuilding images..."
	$(COMPOSE) up -d --build --remove-orphans
	@$(MAKE) --no-print-directory copy-lock
	@echo "✔ All lockfiles synced."
```

### Points clés de cet exemple

- **`make up`** fait tout : build, healthcheck, seed, sync lockfile, affiche les URLs.
- **`test-e2e`** :
  - Utilise un fichier `compose.e2e.yml` dédié avec profil `e2e`.
  - Propage le code de sortie Playwright (`exit $$e2e_exit`).
  - Copie le rapport vers `playwright-report/` et affiche le chemin.
  - Restaure la stack normale après les tests.
  - Supporte le filtrage par tags : `make test-e2e TAGS=ui,flow`.
- **`copy-vendors`** nettoie avant de copier (évite les conflits de symlinks).
- **`copy-lock`** gère gracieusement l'absence du fichier (message warning, pas d'erreur).
- **`lock`** = rebuild + sync (régénère le lockfile à partir des sources).

---

## Exemple 3 : test-api (intégration API)

Quand le projet expose une API REST testée séparément des tests unitaires :

```makefile
test-api: ## Tests d'intégration API
	@printf "\n$(BOLD)Running API integration tests...$(RESET)\n"
	$(EXEC) npm run test:api
	@printf "\n📊 Coverage: apps/backend/coverage/lcov-report/index.html\n"
	@printf "   Open: open apps/backend/coverage/lcov-report/index.html\n"
	@printf "$(GREEN)  API tests passed.$(RESET)\n\n"
```

---

## Patterns réutilisables

### Healthcheck en boucle

```makefile
define wait_for_health
	@for i in $$(seq 1 $(2)); do \
		$(COMPOSE) exec -T $(1) \
			sh -c 'wget -qO /dev/null http://localhost:$${PORT}/health 2>/dev/null' \
			&& break; \
		sleep 2; \
	done
endef

# Usage : $(call wait_for_health,backend,20)
```

### Affichage des ressources

```makefile
BOLD   = \033[1m
CYAN   = \033[36m
GREEN  = \033[32m
YELLOW = \033[33m
RESET  = \033[0m
LINE   = \033[90m──────────────────────────────────────────────────\033[0m

define print_resource
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "$(1)" "$(2)"
endef
```

### Propagation du code de sortie

```makefile
	@exit_code=0; \
	$(SOME_COMMAND) || exit_code=$$?; \
	echo "Artefact: ./path/to/report"; \
	exit $$exit_code
```

Ce pattern permet d'afficher le chemin du rapport même en cas d'échec, tout en propageant l'erreur.
