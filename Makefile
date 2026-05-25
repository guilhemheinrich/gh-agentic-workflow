-include .env
export

.PHONY: sync-registry lint lint-md lint-mdc lint-yaml lint-json lint-sh test-hooks

# ──── Existing targets ─────────────────────────────────────────────────────────

sync-registry: ## Sync and validate the asset registry
	docker run --rm -v $$(pwd):/app -w /app node:22-alpine sh -c "npm install --no-audit --no-fund && npx tsx scripts/sync-asset-registry.ts"

# ──── Lint targets (spec 014) ──────────────────────────────────────────────────

lint: ## Lint a single file routed by extension (FILE=path/to/file)
	@./scripts/lint-route.sh "$(FILE)"

lint-md: ## Lint a Markdown or MDC file with markdownlint-cli2 (FILE=path/to/file)
	@docker run --rm \
	  -v $$(pwd):/work -w /work \
	  davidanson/markdownlint-cli2:latest \
	  "$(FILE)" \
	  || exit 1

lint-mdc: ## Lint an MDC file (treated as Markdown)
	@$(MAKE) lint-md FILE="$(FILE)"

lint-yaml: ## Lint a YAML file with yamllint (FILE=path/to/file)
	@docker run --rm \
	  -v $$(pwd):/work -w /work \
	  cytopia/yamllint:latest \
	  -s "$(FILE)" \
	  || exit 1

lint-json: ## Check JSON syntax with jq (FILE=path/to/file)
	@docker run --rm \
	  -v $$(pwd):/work -w /work \
	  ghcr.io/jqlang/jq:latest \
	  'empty' "$(FILE)" >/dev/null \
	  || exit 1

lint-sh: ## Lint a shell script with shellcheck (FILE=path/to/file)
	@docker run --rm \
	  -v $$(pwd):/work -w /work \
	  koalaman/shellcheck-alpine:stable \
	  shellcheck --severity=warning "$(FILE)" \
	  || exit 1

# ──── Test targets ─────────────────────────────────────────────────────────────

test-hooks: ## Run Bats unit tests for the lint-on-edit hook suite
	@docker run --rm \
	  -v $$(pwd):/workspace -w /workspace \
	  bats/bats:latest \
	  tests/hooks/
