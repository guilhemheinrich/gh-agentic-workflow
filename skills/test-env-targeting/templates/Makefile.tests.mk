# Makefile.tests.mk — test entry points, one per category, all parameterised
# by ENV. Include from the root Makefile:
#
#   include tests/Makefile.tests.mk
#
#   make test-api                                  # local (default)
#   make test-e2e ENV=staging LANE=fast
#   make test-e2e-business ENV=staging             # mutating tests, one worker
#   make test-e2e-list ENV=prod PROD_CONFIRM=1     # always list before a prod run
#   make test-e2e ENV=prod PROD_CONFIRM=1
#
# TRAP — a root Makefile that does `-include .env` + `export` pushes the app's
# runtime .env into every recipe. with-env.sh lets the caller win, so a
# stray E2E_BASE_URL in the root .env would silently beat tests/env/.env.staging.
# Keep test-target variables out of the root .env, or `unexport` them here.

ENV ?= local
LANE ?=
TEST_ENV_DIR ?= tests/env
PW_CONFIG := tests/playwright.config.ts

# A mistyped lane would match nothing and exit 0: a false-green run.
LANES := fast slow
ifneq ($(LANE),)
ifeq ($(filter $(LANE),$(LANES)),)
$(error LANE must be one of: $(LANES) (got '$(LANE)'))
endif
endif

# Run flags reach with-env.sh as options, and only when the assignment was
# typed on THIS make command line. `export PROD_CONFIRM=1` in a shell profile
# has origin "environment" and is ignored.
PROD_FLAG := $(if $(and $(filter command line,$(origin PROD_CONFIRM)),$(filter 1,$(PROD_CONFIRM))),--confirm-prod,)
LIVE_FLAG := $(if $(and $(filter command line,$(origin TEST_LIVE)),$(filter 1,$(TEST_LIVE))),--live,)
WITH_ENV := bash $(TEST_ENV_DIR)/with-env.sh $(PROD_FLAG) $(LIVE_FLAG) $(ENV) --

# Tag filter: the AND of the lane (if any) and the prod allowlist (on prod),
# written as lookaheads so that one --grep carries both.
empty :=
space := $(empty) $(empty)
TAGS := $(if $(LANE),@$(LANE)) $(if $(filter prod,$(ENV)),@prod-safe)
PW_GREP := $(if $(strip $(TAGS)),--grep '$(subst $(space),,$(foreach t,$(strip $(TAGS)),(?=.*$(t))))',)
GO_RUN := $(if $(filter prod,$(ENV)),-run '^TestProdSafe_',)

# Local targets need the compose stack. `up` is the root Makefile's target
# (compose up --wait with healthchecks); remote targets depend on nothing.
STACK := $(if $(filter local,$(ENV)),up,)

# Categories that never target prod refuse before calling the loader.
define REFUSE_PROD
	@test "$(ENV)" != "prod" || { echo "$@: never targets prod" >&2; exit 2; }
endef

.PHONY: test-env test-api test-api-list test-api-business test-e2e test-e2e-list test-e2e-business \
        test-integration test-api-go test-integration-go test-load-smoke

test-env: ## Print the resolved test target for ENV (never prints secrets)
	@$(WITH_ENV) true

test-api: $(STACK) ## API tests against ENV (default: local)
	$(WITH_ENV) npx playwright test --config $(PW_CONFIG) --project api $(PW_GREP)

test-api-list: ## List what test-api WOULD run against ENV — mandatory before prod
	$(WITH_ENV) npx playwright test --config $(PW_CONFIG) --project api $(PW_GREP) --list

test-api-business: $(STACK) ## Mutating API tests against ENV, one worker (never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) npx playwright test --config $(PW_CONFIG) --project api --grep @business --workers=1

test-e2e: $(STACK) ## Browser e2e tests against ENV (LANE=fast|slow narrows)
	$(WITH_ENV) npx playwright test --config $(PW_CONFIG) --project e2e $(PW_GREP)

test-e2e-list: ## List what test-e2e WOULD run against ENV — mandatory before prod
	$(WITH_ENV) npx playwright test --config $(PW_CONFIG) --project e2e $(PW_GREP) --list

test-e2e-business: $(STACK) ## Mutating e2e tests against ENV, one worker (never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) npx playwright test --config $(PW_CONFIG) --project e2e --grep @business --workers=1

test-integration: $(STACK) ## Integration tests on local backing services (TEST_LIVE=1 opts a remote target in; never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) npx vitest run --config tests/integration/vitest.integration.config.ts

test-api-go: $(STACK) ## Go API tests against ENV (build tag: api)
	$(WITH_ENV) go test -tags api ./tests/api/... $(GO_RUN) -count=1 -v

test-integration-go: $(STACK) ## Go integration tests, local only (build tag: integration; never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) go test -tags integration ./tests/integration/... -count=1 -v

test-load-smoke: $(STACK) ## k6 smoke against ENV (never prod)
	$(REFUSE_PROD)
	$(WITH_ENV) k6 run tests/load/smoke.js
