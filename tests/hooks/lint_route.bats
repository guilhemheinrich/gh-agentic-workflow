#!/usr/bin/env bats
# tests/hooks/lint_route.bats
# Exercises the inline glob→docker dispatch in the root Makefile's `lint:` recipe.
# Uses tests/hooks/fixtures/Makefile.stub which mirrors the real Makefile's case
# structure but replaces docker invocations with controllable stubs.
#
# Run via: make test-hooks
# Or directly: docker run --rm -v $(pwd):/workspace -w /workspace bats/bats:latest tests/hooks/
#
# Note: GNU make wraps any recipe non-zero exit to its own status 2 and prints
# `make: *** [Makefile:N: lint] Error <code>` on stderr. We assert on the
# wrapped status AND on the `Error <code>` marker in the captured output.

FIXTURE_MAKE="$BATS_TEST_DIRNAME/fixtures/Makefile.stub"

setup() {
  TEST_PROJECT="$(mktemp -d)"
  mkdir -p \
    "$TEST_PROJECT/src" \
    "$TEST_PROJECT/docs" \
    "$TEST_PROJECT/scripts" \
    "$TEST_PROJECT/node_modules" \
    "$TEST_PROJECT/dist" \
    "$TEST_PROJECT/.git" \
    "$TEST_PROJECT/vendor"
  cp "$FIXTURE_MAKE" "$TEST_PROJECT/Makefile"

  : >"$TEST_PROJECT/src/foo.ts"
  : >"$TEST_PROJECT/docs/readme.md"
  : >"$TEST_PROJECT/docs/config.yml"
  : >"$TEST_PROJECT/src/data.json"
  : >"$TEST_PROJECT/scripts/helper.sh"
  : >"$TEST_PROJECT/src/logo.png"
  : >"$TEST_PROJECT/src/foo.broken"
  : >"$TEST_PROJECT/src/foo.xyz"
  : >"$TEST_PROJECT/node_modules/foo.js"
  : >"$TEST_PROJECT/dist/bundle.js"
  : >"$TEST_PROJECT/.git/COMMIT_EDITMSG"
  : >"$TEST_PROJECT/vendor/lib.go"
  : >"$TEST_PROJECT/package.lock"
  : >"$TEST_PROJECT/.env"

  export STUB_LINT_EXIT=0
  export STUB_LINT_OUTPUT="stub: ok"
}

teardown() {
  rm -rf "$TEST_PROJECT"
}

# ── No argument ────────────────────────────────────────────────────────────────

@test "no FILE exits non-zero, message 'FILE=... is required', Error 64" {
  run make -C "$TEST_PROJECT" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"FILE=... is required"* ]]
  [[ "$output" == *"Error 64"* ]]
}

# ── Excluded paths (silent allow, exit 0) ─────────────────────────────────────

@test "file under node_modules/ exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE="node_modules/foo.js"
  [ "$status" -eq 0 ]
}

@test "file under dist/ exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE="dist/bundle.js"
  [ "$status" -eq 0 ]
}

@test "file under .git/ exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE=".git/COMMIT_EDITMSG"
  [ "$status" -eq 0 ]
}

@test "file under vendor/ exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE="vendor/lib.go"
  [ "$status" -eq 0 ]
}

# ── Ignored extensions (silent allow, exit 0) ──────────────────────────────────

@test "PNG file exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE="src/logo.png"
  [ "$status" -eq 0 ]
}

@test ".lock file exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE="package.lock"
  [ "$status" -eq 0 ]
}

@test ".env file exits 0 silently" {
  run make -C "$TEST_PROJECT" lint FILE=".env"
  [ "$status" -eq 0 ]
}

# ── Routed extensions (dispatch to stub) ──────────────────────────────────────

@test "TS file routes to stub, passes with STUB_LINT_EXIT=0" {
  run make -C "$TEST_PROJECT" lint FILE="src/foo.ts"
  [ "$status" -eq 0 ]
}

@test "MD file routes to stub, passes with STUB_LINT_EXIT=0" {
  run make -C "$TEST_PROJECT" lint FILE="docs/readme.md"
  [ "$status" -eq 0 ]
}

@test "YAML file routes to stub, passes with STUB_LINT_EXIT=0" {
  run make -C "$TEST_PROJECT" lint FILE="docs/config.yml"
  [ "$status" -eq 0 ]
}

@test "JSON file routes to stub, passes with STUB_LINT_EXIT=0" {
  run make -C "$TEST_PROJECT" lint FILE="src/data.json"
  [ "$status" -eq 0 ]
}

@test "SH file routes to stub, passes with STUB_LINT_EXIT=0" {
  run make -C "$TEST_PROJECT" lint FILE="scripts/helper.sh"
  [ "$status" -eq 0 ]
}

@test "stub linter failure (STUB_LINT_EXIT=1) is propagated" {
  run make -C "$TEST_PROJECT" lint FILE="src/foo.ts" STUB_LINT_EXIT=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error 1"* ]]
}

@test "wiring missing (.broken → exit 65) is propagated" {
  run make -C "$TEST_PROJECT" lint FILE="src/foo.broken"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error 65"* ]]
  [[ "$output" == *"wire it up"* ]]
}

# ── Policy gap (exit 64) ───────────────────────────────────────────────────────

@test "unknown extension .xyz exits 64 with policy-gap message" {
  run make -C "$TEST_PROJECT" lint FILE="src/foo.xyz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error 64"* ]]
  [[ "$output" == *"no case matches"* ]]
  [[ "$output" == *"foo.xyz"* ]]
}

@test "policy-gap message points the agent at the Makefile" {
  run make -C "$TEST_PROJECT" lint FILE="src/foo.xyz"
  [[ "$output" == *"lint:"*"recipe"* ]] || [[ "$output" == *"Makefile"* ]]
}
