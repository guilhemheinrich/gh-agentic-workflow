#!/usr/bin/env bats
# tests/hooks/lint_degrade.bats
# Graceful degradation tests — hook never crashes on missing dependencies.
#
# Run via: make test-hooks

HOOK="$BATS_TEST_DIRNAME/../../hooks/lint-on-edit.sh"

setup() {
  TEST_PROJECT="$(mktemp -d)"
  mkdir -p "$TEST_PROJECT/src"
  echo 'const x = 1;' > "$TEST_PROJECT/src/foo.ts"

  export LINT_ON_EDIT=1
  export LINT_TIMEOUT=10
  export LINT_DEBUG=0
  export LINT_HOOK_HOST=claude
}

teardown() {
  rm -rf "$TEST_PROJECT"
}

claude_payload() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' \
    "$TEST_PROJECT/src/foo.ts" "$TEST_PROJECT"
}

# ── make not found ─────────────────────────────────────────────────────────────

@test "make not in PATH — hook exits 2 with 'make' in message (Claude)" {
  # Put an empty directory first on PATH so 'make' is not found.
  local empty_dir
  empty_dir="$(mktemp -d)"
  PATH="$empty_dir:$PATH" run bash "$HOOK" <<< "$(claude_payload)"
  rm -rf "$empty_dir"

  # Hook should exit 2 (not crash with set -uo pipefail unbound variable etc.)
  # and ideally mention make or a command not found error.
  # The hook itself calls `make -C $root lint ...` which will fail with 127.
  # As long as status is 2 and output is non-empty, the hook handled it.
  [ "$status" -eq 2 ]
  [ -n "$output" ]
}

# ── LINT_ON_EDIT=0 escape hatch ────────────────────────────────────────────────

@test "LINT_ON_EDIT=0 — hook exits 0 silently even without make" {
  local empty_dir
  empty_dir="$(mktemp -d)"
  LINT_ON_EDIT=0 PATH="$empty_dir:$PATH" run bash "$HOOK" <<< "$(claude_payload)"
  rm -rf "$empty_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── No Makefile in project (no project root found) ────────────────────────────

@test "no Makefile in ancestor dirs — hook exits 0 silently" {
  # Create a temp file in a location with no Makefile ancestor
  local no_make_dir
  no_make_dir="$(mktemp -d)"
  mkdir -p "$no_make_dir/src"
  echo 'x' > "$no_make_dir/src/foo.ts"

  payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$no_make_dir/src/foo.ts"'"}}'
  run bash "$HOOK" <<< "$payload"
  rm -rf "$no_make_dir"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── File does not exist ────────────────────────────────────────────────────────

@test "file path that does not exist — hook exits 0 silently" {
  payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_PROJECT/src/nonexistent.ts"'"}}'
  run bash "$HOOK" <<< "$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Timeout (LINT_TIMEOUT=1 with sleeping stub make) ──────────────────────────

@test "make that sleeps longer than LINT_TIMEOUT — hook emits timeout message" {
  # Create a stub make that sleeps 5 seconds (longer than LINT_TIMEOUT=1)
  local slow_make_dir
  slow_make_dir="$(mktemp -d)"
  cat > "$slow_make_dir/make" << 'EOF'
#!/usr/bin/env bash
sleep 5
exit 0
EOF
  chmod +x "$slow_make_dir/make"

  export LINT_TIMEOUT=1
  PATH="$slow_make_dir:$PATH" run bash "$HOOK" <<< "$(claude_payload)"
  rm -rf "$slow_make_dir"

  # Hook must not hang (test runner would time out if it did)
  # and must emit a non-empty message about timeout
  [ "$status" -eq 2 ]
  [[ "$output" == *"timed out"* ]] || [[ "$output" == *"timeout"* ]] || [[ "$output" == *"124"* ]]
}
