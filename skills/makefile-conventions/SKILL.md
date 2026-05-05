---
name: makefile-conventions
description: >-
  Write project-root Makefiles with Docker-first execution, .env-driven
  configuration, and standardized targets. Use when authoring or debugging
  Makefiles, adding make targets, configuring docker compose orchestration,
  or when the user mentions "Makefile", "make up", "make test", or
  "docker compose" workflow.
---

# Makefile — conventions et templates

## Principes fondamentaux

1. **Docker-first** : toutes les commandes s'exécutent dans des conteneurs, jamais sur l'hôte.
2. **Configuration par `.env`** : tous les ports, URLs, images sont lus depuis `.env` avec des fallbacks `?=`.
3. **Sortie exploitable** : après un `make up`, les URLs/ports sont affichés et cliquables dans le terminal. Après des tests, le chemin vers le rapport est indiqué.
4. **`.PHONY`** : tous les targets non-fichier sont déclarés PHONY.

---

## Structure du fichier

```makefile
# ──── Configuration ───────────────────────────────────────────
-include .env
export

# Fallbacks (valeurs .env.example)
APP_PORT     ?= 3000
API_PORT     ?= 8080

# ──── Variables dérivées ──────────────────────────────────────
COMPOSE      = docker compose
EXEC_BACKEND = $(COMPOSE) exec -T backend
RUN_BACKEND  = $(COMPOSE) run --rm backend

APP_URL      ?= http://localhost:$(APP_PORT)
API_URL      ?= http://localhost:$(API_PORT)

# ──── Helpers (affichage) ─────────────────────────────────────
BOLD   = \033[1m
CYAN   = \033[36m
GREEN  = \033[32m
YELLOW = \033[33m
RESET  = \033[0m
LINE   = \033[90m──────────────────────────────────────────────────\033[0m

define print_resource
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "$(1)" "$(2)"
endef

# ──── PHONY ───────────────────────────────────────────────────
.PHONY: help up down copy-vendors locks test test-e2e test-api
.DEFAULT_GOAL := help
```

> **`-include .env`** (avec le tiret) empêche une erreur si `.env` n'existe pas encore.

---

## Targets obligatoires

### `help` — affiche les targets disponibles

```makefile
help: ## Affiche les targets disponibles
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
```

### `up` — démarrage de la stack

Démarre tous les services et affiche les ressources exposées (URLs cliquables).

```makefile
up: ## Démarre la stack complète
	@printf "\n$(BOLD)Starting services...$(RESET)\n"
	@$(COMPOSE) up -d --build --remove-orphans
	@printf "\n$(LINE)\n"
	@printf "$(BOLD)$(GREEN)  Stack is up$(RESET)\n"
	@printf "$(LINE)\n"
	$(call print_resource,App,$(APP_URL))
	$(call print_resource,API,$(API_URL))
	$(call print_resource,API Docs,$(API_URL)/api)
	@printf "$(LINE)\n"
	@printf "  $(YELLOW)Logs$(RESET)  make logs     $(YELLOW)Stop$(RESET)  make down\n\n"
```

**Règles** :
- Chaque service avec un port exposé doit apparaître dans la sortie.
- Utiliser `$(call print_resource,Label,URL)` pour un formatage cohérent.
- Les ports viennent de variables `?=`, jamais en dur.

### `down` — arrêt de la stack

```makefile
down: ## Arrête tous les services
	@$(COMPOSE) down
```

### `copy-vendors` — sync des dépendances pour le LSP hôte

Copie les `node_modules` (ou équivalent) du conteneur vers l'hôte pour que le LSP et le linter de l'IDE fonctionnent.

```makefile
copy-vendors: ## Copie node_modules des conteneurs vers l'hôte (IDE)
	@printf "\n$(BOLD)Syncing node_modules to host...$(RESET)\n"
	rm -rf ./node_modules
	$(COMPOSE) cp backend:/app/node_modules ./node_modules
	@printf "$(GREEN)  node_modules synced. IDE linter should resolve deps.$(RESET)\n\n"
```

**Règles** :
- Toujours `rm -rf` l'ancien dossier avant la copie (évite les conflits de symlinks).
- Adapter le nombre de `cp` au nombre de packages/apps du monorepo.

### `locks` — copie des lockfiles

Copie le lockfile généré dans le conteneur vers l'hôte (pour le versionning et la CI).

```makefile
locks: ## Copie les lockfiles du conteneur vers l'hôte
	@printf "\n$(BOLD)Exporting lockfiles...$(RESET)\n"
	@$(COMPOSE) cp backend:/build-lock/bun.lock ./bun.lock 2>/dev/null \
		&& printf "$(GREEN)  bun.lock copied.$(RESET)\n" \
		|| printf "$(YELLOW)  bun.lock not found (rebuild with make up).$(RESET)\n"
```

### `test` — tests unitaires

```makefile
test: ## Tests unitaires
	@printf "\n$(BOLD)Running unit tests...$(RESET)\n"
	$(EXEC_BACKEND) npm run test
	@printf "$(GREEN)  Tests passed.$(RESET)\n\n"
```

### `test-e2e` — tests end-to-end (Playwright)

Utilise un `compose.e2e.yml` dédié. La sortie affiche le chemin du rapport.

```makefile
test-e2e: ## Tests E2E (Playwright, compose.e2e.yml)
	$(COMPOSE) -f compose.yml -f compose.e2e.yml --profile e2e up -d --build
	@printf "⏳ Waiting for services...\n"
	@for i in $$(seq 1 20); do \
		$(COMPOSE) -f compose.yml -f compose.e2e.yml exec -T backend \
			sh -c 'wget -qO /dev/null http://localhost:$${PORT:-3000}/health 2>/dev/null' \
			&& break; \
		sleep 2; \
	done
	@e2e_exit=0; \
	$(COMPOSE) -f compose.yml -f compose.e2e.yml --profile e2e \
		run --rm playwright npx playwright test || e2e_exit=$$?; \
	rm -rf playwright-report && \
		cp -r apps/e2e/playwright-report playwright-report 2>/dev/null || true; \
	printf "\n📊 Rapport E2E : playwright-report/index.html\n"; \
	printf "   Ouvrir     : open playwright-report/index.html\n\n"; \
	exit $$e2e_exit
```

**Règles** :
- Toujours copier le rapport vers un emplacement connu et l'indiquer en sortie.
- Restaurer la stack normale après les tests si le profil E2E modifie des services.
- Le code de sortie de Playwright doit être propagé (`exit $$e2e_exit`).

### `test-api` — tests d'API (le cas échéant)

```makefile
test-api: ## Tests d'API (integration)
	@printf "\n$(BOLD)Running API tests...$(RESET)\n"
	$(EXEC_BACKEND) npm run test:api
	@printf "$(GREEN)  API tests passed.$(RESET)\n\n"
```

---

## Bonnes pratiques

### Variables `.env` avec fallback

```makefile
-include .env
export

BACKEND_PORT ?= 3000
FRONTEND_PORT ?= 3001
DB_PORT ?= 5432
```

- Utiliser `-include` (silencieux si absent).
- Toujours définir un fallback `?=` cohérent avec `.env.example`.
- Exposer via `export` pour que les subshells héritent.

### Sortie des ressources créées

Quand un target produit un artefact (rapport de test, fichier généré), **toujours** afficher le chemin :

```makefile
	@printf "\n📊 Report: ./coverage/lcov-report/index.html\n"
	@printf "   Open: open ./coverage/lcov-report/index.html\n"
```

### Affichage des URLs dans `up`

Utiliser la macro `print_resource` pour un alignement propre et des URLs cliquables :

```makefile
define print_resource
	@printf "  $(CYAN)%-18s$(RESET) %s\n" "$(1)" "$(2)"
endef

# Usage :
$(call print_resource,App,http://localhost:$(APP_PORT))
$(call print_resource,API Docs,http://localhost:$(API_PORT)/api)
$(call print_resource,DB Studio,http://localhost:$(DB_STUDIO_PORT))
```

### Healthcheck avant action

Quand un target dépend d'un service prêt (E2E, seed), boucler sur un healthcheck :

```makefile
@for i in $$(seq 1 20); do \
    $(COMPOSE) exec -T backend \
        sh -c 'wget -qO /dev/null http://localhost:$${PORT}/health 2>/dev/null' \
        && break; \
    sleep 2; \
done
```

### Monorepo : adapter les commandes par service

```makefile
EXEC_BACKEND  = $(COMPOSE) exec -T backend
EXEC_FRONTEND = $(COMPOSE) exec -T frontend
EXEC_WORKER   = $(COMPOSE) exec -T worker

test:
	$(EXEC_BACKEND) npm run test
	$(EXEC_FRONTEND) npm run test
	$(EXEC_WORKER) npm run test
```

---

## Anti-patterns

| Anti-pattern | Correction |
|---|---|
| Port hardcodé (`localhost:3000`) | `http://localhost:$(APP_PORT)` |
| Commande directe sur l'hôte (`npm test`) | `$(EXEC_BACKEND) npm test` |
| Pas de `.PHONY` | Déclarer tous les targets |
| `include .env` sans `-` | `-include .env` (silencieux si absent) |
| Test E2E sans rapport de sortie | Toujours afficher le chemin du rapport |
| `make up` muet | Toujours lister les ressources exposées |

---

## Ressources complémentaires

- Pour des exemples complets de Makefiles réels, voir [examples.md](examples.md)
