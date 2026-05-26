-include .env
export

.PHONY: sync-registry test-hooks

# ──── Repo targets ─────────────────────────────────────────────────────────────
# NOTE: this repo distributes the lint-on-edit template (hook + Makefile recipe)
# via skills/makefile-lint-router/. It does NOT lint itself — `make lint` lives
# in *consumer* repos that adopt the skill.

sync-registry: ## Sync and validate the asset registry
	docker run --rm -v $$(pwd):/app -w /app node:22-alpine sh -c "npm install --no-audit --no-fund && npx tsx scripts/sync-asset-registry.ts"

test-hooks: ## Run Bats unit tests for the lint-on-edit hook template
	@docker run --rm \
	  -v $$(pwd):/workspace -w /workspace \
	  --entrypoint sh \
	  bats/bats:latest \
	  -c "apk add --no-cache make >/dev/null && bats tests/hooks/"
