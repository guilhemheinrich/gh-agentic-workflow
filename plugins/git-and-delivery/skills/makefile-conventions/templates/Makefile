# Root Makefile template: Docker-first, .env-driven.
# ---- Configuration ---------------------------------------------------------
-include .env
export

# Fallbacks, keep identical to .env.example
APP_PORT ?= 3000
API_PORT ?= 8080

# ---- Derived variables ------------------------------------------------------
COMPOSE      = docker compose
EXEC_BACKEND = $(COMPOSE) exec -T backend
RUN_BACKEND  = $(COMPOSE) run --rm backend

APP_URL ?= http://localhost:$(APP_PORT)
API_URL ?= http://localhost:$(API_PORT)

# ---- Output helpers -----------------------------------------------------------
BOLD   = \033[1m
CYAN   = \033[36m
GREEN  = \033[32m
YELLOW = \033[33m
RESET  = \033[0m
LINE   = \033[90m--------------------------------------------------\033[0m

define print_resource
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "$(1)" "$(2)"
endef

.PHONY: help up down logs copy-vendors copy-lock lock test test-e2e test-api
.DEFAULT_GOAL := help

# Awk fields are written $$(1) / $$(2): equivalent to $$1 / $$2, and safe when a SKILL.md
# is invoked as a slash command (a bare "$" followed by a digit is replaced by an argument).
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$(1), $$(2)}'

up: ## Start the full stack and print the exposed resources
	@printf "\n$(BOLD)Starting services...$(RESET)\n"
	@$(COMPOSE) up -d --build --remove-orphans
	@printf "\n$(LINE)\n$(BOLD)$(GREEN)  Stack is up$(RESET)\n$(LINE)\n"
	$(call print_resource,App,$(APP_URL))
	$(call print_resource,API,$(API_URL))
	$(call print_resource,API Docs,$(API_URL)/api)
	@printf "$(LINE)\n  $(YELLOW)Logs$(RESET)  make logs     $(YELLOW)Stop$(RESET)  make down\n\n"

down: ## Stop all services
	@$(COMPOSE) down

logs: ## Follow logs (make logs S=backend)
	@$(COMPOSE) logs -f $(S)

# Copy dependencies from the container to the host so the IDE/LSP resolves them.
# Always delete the old directory first (avoids symlink conflicts); repeat the cp per package in a monorepo.
copy-vendors: ## Copy node_modules from containers to the host (IDE)
	rm -rf ./node_modules
	$(COMPOSE) cp backend:/app/node_modules ./node_modules
	@$(MAKE) --no-print-directory copy-lock

# A missing lockfile is a warning, not an error.
copy-lock: ## Copy the lockfile from the container to the host
	@$(COMPOSE) cp backend:/build-lock/bun.lock ./bun.lock 2>/dev/null \
		&& printf "$(GREEN)  bun.lock copied.$(RESET)\n" \
		|| printf "$(YELLOW)  bun.lock not found (rebuild with make up).$(RESET)\n"

lock: ## Rebuild images and copy the regenerated lockfile
	$(COMPOSE) up -d --build --remove-orphans
	@$(MAKE) --no-print-directory copy-lock

test: ## Unit tests
	$(EXEC_BACKEND) npm run test

test-api: ## API integration tests
	$(EXEC_BACKEND) npm run test:api

# Optional: TAGS=a,b runs Playwright with --grep "@a|@b".
PW_GREP := $(if $(TAGS),--grep "$(shell echo '$(TAGS)' | sed 's/,/|@/g' | sed 's/^/@/')",)
E2E_COMPOSE = $(COMPOSE) -f compose.yml -f compose.e2e.yml

# Wait for health, propagate the Playwright exit code, always print the report path.
test-e2e: ## E2E tests (Playwright, compose.e2e.yml). Optional: TAGS=a,b
	$(E2E_COMPOSE) --profile e2e up -d --build
	@printf "Waiting for services...\n"
	@for i in $$(seq 1 20); do \
		$(E2E_COMPOSE) exec -T backend \
			sh -c 'wget -qO /dev/null http://localhost:$${PORT:-3000}/health 2>/dev/null' \
			&& break; \
		sleep 2; \
	done
	@e2e_exit=0; \
	$(E2E_COMPOSE) --profile e2e run --rm playwright npx playwright test $(PW_GREP) || e2e_exit=$$?; \
	rm -rf playwright-report && cp -r apps/e2e/playwright-report playwright-report 2>/dev/null || true; \
	printf "\nE2E report: playwright-report/index.html\n"; \
	$(COMPOSE) up -d backend --build; \
	exit $$e2e_exit
