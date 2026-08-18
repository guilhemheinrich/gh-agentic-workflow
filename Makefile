-include .env
export

.PHONY: sync-registry

# ──── Repo targets ─────────────────────────────────────────────────────────────
# NOTE: this repo distributes the static-validation hook template via
# skills/static-validation-hooks/. It does NOT validate itself — the hook is
# installed in *consumer* repos that adopt the skill.

sync-registry: ## Sync and validate the asset registry
	docker run --rm -v $$(pwd):/app -w /app node:22-alpine sh -c "npm install --no-audit --no-fund && npx tsx scripts/sync-asset-registry.ts"
