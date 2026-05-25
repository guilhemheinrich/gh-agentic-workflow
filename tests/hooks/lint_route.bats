#!/usr/bin/env bats
# tests/hooks/lint_route.bats
# Unit tests for scripts/lint-route.sh
#
# Run via: make test-hooks
# Or directly: docker run --rm -v $(pwd):/workspace -w /workspace bats/bats:latest tests/hooks/

ROUTER="$BATS_TEST_DIRNAME/../../scripts/lint-route.sh"
FIXTURE_MAKE="$BATS_TEST_DIRNAME/fixtures/Makefile.stub"

# ── Setup / teardown ───────────────────────────────────────────────────────────

setup() {
  # Create a temp project directory that mirrors the router's expected layout.
  TEST_PROJECT="$(mktemp -d)"

  # Copy router script and stub Makefile into the temp project.
  mkdir -p "$TEST_PROJECT/scripts" "$TEST_PROJECT/src" "$TEST_PROJECT/docs"
  cp "$ROUTER" "$TEST_PROJECT/scripts/lint-route.sh"
  chmod +x "$TEST_PROJECT/scripts/lint-route.sh"
  cp "$FIXTURE_MAKE" "$TEST_PROJECT/Makefile"

  # Create test files.
  echo 'const x = 1;'   > "$TEST_PROJECT/src/foo.ts"
  echo '# Hello'        > "$TEST_PROJECT/docs/readme.md"
  echo 'key: value'     > "$TEST_PROJECT/docs/config.yml"
  echo '{"a":1}'        > "$TEST_PROJECT/src/data.json"
  echo '#!/bin/bash'    > "$TEST_PROJECT/scripts/helper.sh"

  # Default stub behavior: pass.
  export STUB_LINT_EXIT=0
  export STUB_LINT_OUTPUT="stub: ok"
}

teardown() {
  rm -rf "$TEST_PROJECT"
}

# ── No argument ────────────────────────────────────────────────────────────────

@test "no argument exits 64 with usage message" {
  run bash "$ROUTER"
  [ "$status" -eq 64 ]
  [[ "$output" == *"FILE argument is required"* ]]
}

@test "empty argument exits 64 with usage message" {
  run bash "$ROUTER" ""
  [ "$status" -eq 64 ]
}

# ── Excluded paths (silent allow, exit 0) ─────────────────────────────────────

@test "file under node_modules/ exits 0 silently" {
  run bash "$ROUTER" "node_modules/lodash/index.js"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "file under dist/ exits 0 silently" {
  run bash "$ROUTER" "dist/bundle.js"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "file under .git/ exits 0 silently" {
  run bash "$ROUTER" ".git/COMMIT_EDITMSG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "file under vendor/ exits 0 silently" {
  run bash "$ROUTER" "vendor/foo/bar.go"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Ignored extensions (silent allow, exit 0) ──────────────────────────────────

@test "PNG file exits 0 silently" {
  run bash "$ROUTER" "assets/logo.png"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lock file exits 0 silently" {
  run bash "$ROUTER" "package.lock"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test ".lockb file exits 0 silently" {
  run bash "$ROUTER" "bun.lockb"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test ".env file exits 0 silently" {
  run bash "$ROUTER" ".env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test ".gitignore exits 0 silently (dot-file: no conventional extension)" {
  run bash "$ROUTER" ".gitignore"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Routed extensions (dispatched to sub-targets) ─────────────────────────────
# These tests run the router from the test project directory so make can find
# the Makefile.stub targets.

@test "TS file routes to lint-ts and exits with stub result" {
  export STUB_LINT_EXIT=0
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'src/foo.ts'"
  [ "$status" -eq 0 ]
}

@test "MD file routes to lint-md and exits with stub result" {
  export STUB_LINT_EXIT=0
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'docs/readme.md'"
  [ "$status" -eq 0 ]
}

@test "YAML file routes to lint-yaml and exits with stub result" {
  export STUB_LINT_EXIT=0
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'docs/config.yml'"
  [ "$status" -eq 0 ]
}

@test "JSON file routes to lint-json and exits with stub result" {
  export STUB_LINT_EXIT=0
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'src/data.json'"
  [ "$status" -eq 0 ]
}

@test "SH file routes to lint-sh and exits with stub result" {
  export STUB_LINT_EXIT=0
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'scripts/helper.sh'"
  [ "$status" -eq 0 ]
}

@test "linter sub-target failure (exit 1) is propagated" {
  export STUB_LINT_EXIT=1
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'src/foo.ts'"
  [ "$status" -eq 1 ]
}

@test "wiring missing (exit 65 from sub-target) is propagated" {
  # The Makefile.stub has a lint-broken target that exits 65.
  # Route a .ts file but force the stub to return 65.
  export STUB_LINT_EXIT=65
  run bash -c "cd '$TEST_PROJECT' && bash scripts/lint-route.sh 'src/foo.ts'"
  [ "$status" -eq 65 ]
}

# ── Policy gap (exit 64) ───────────────────────────────────────────────────────

@test "unknown extension .xyz exits 64 with policy gap message" {
  run bash "$ROUTER" "src/foo.xyz"
  [ "$status" -eq 64 ]
  [[ "$output" == *".xyz"* ]]
}

@test "unknown extension .abc exits 64 with LINT_ROUTES/LINT_IGNORED instruction" {
  run bash "$ROUTER" "src/foo.abc"
  [ "$status" -eq 64 ]
  [[ "$output" == *"LINT_ROUTES"* ]] || [[ "$output" == *"LINT_IGNORED"* ]]
}

# ── Route-table fixture byte-equality check ────────────────────────────────────
# Assert that the routing arrays in the canonical script and in contracts/fixtures/
# route-table-fixture.sh declare the same extension set.

@test "LINT_ROUTES extensions in fixture match canonical script" {
  local fixture="$BATS_TEST_DIRNAME/../../specs/014-lint-on-edit-hook/contracts/fixtures/route-table-fixture.sh"
  local canonical="$BATS_TEST_DIRNAME/../../scripts/lint-route.sh"

  # Extract all ext:target pairs from canonical script
  canonical_routes="$(grep -o '"\.[a-z]*:[a-z-]*"' "$canonical" | sort)"
  # Extract from fixture
  fixture_routes="$(grep -o '"\.[a-z]*:[a-z-]*"' "$fixture" | sort)"

  [ "$canonical_routes" = "$fixture_routes" ]
}
