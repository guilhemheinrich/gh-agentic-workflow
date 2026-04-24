.PHONY: sync-registry

sync-registry:
	docker run --rm -v $$(pwd):/app -w /app node:22-alpine sh -c "npm install --no-audit --no-fund && npx tsx scripts/sync-asset-registry.ts"
