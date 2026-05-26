#!/usr/bin/env bats
# tests/hooks/lint_parity.bats
# Editor-parity tests: same hook script, same Makefile, same agentMessage content
# regardless of whether the payload is Claude-shaped or Cursor-shaped.
#
# Run via: make test-hooks

HOOK="$BATS_TEST_DIRNAME/../../hooks/lint-on-edit.sh"
STUB_MAKE_DIR="$BATS_TEST_DIRNAME/fixtures/stub-make"

setup() {
  TEST_PROJECT="$(mktemp -d)"
  mkdir -p "$TEST_PROJECT/src"
  echo 'const x = 1;' > "$TEST_PROJECT/src/foo.ts"
  # Empty Makefile so the hook's find_project_root succeeds; the real make
  # invocation is intercepted by stub-make first on PATH below.
  : >"$TEST_PROJECT/Makefile"

  export PATH="$STUB_MAKE_DIR:$PATH"
  export LINT_ON_EDIT=1
  export LINT_TIMEOUT=10
  export LINT_DEBUG=0
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="src/foo.ts:1 error: unused variable 'x'"

  chmod +x "$STUB_MAKE_DIR/make"
}

teardown() {
  rm -rf "$TEST_PROJECT"
}

# Build payloads for the same file
claude_payload() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' \
    "$TEST_PROJECT/src/foo.ts" "$TEST_PROJECT"
}

cursor_payload() {
  printf '{"event":"afterFileEdit","file_path":"%s","workspace_folder":"%s"}' \
    "$TEST_PROJECT/src/foo.ts" "$TEST_PROJECT"
}

# ── Same agentMessage substring regardless of host ────────────────────────────

@test "same lint failure produces same diagnostic substring for Claude and Cursor" {
  export LINT_HOOK_HOST=claude
  run bash "$HOOK" <<< "$(claude_payload)"
  [ "$status" -eq 2 ]
  claude_msg="$output"

  export LINT_HOOK_HOST=cursor
  run bash "$HOOK" <<< "$(cursor_payload)"
  [ "$status" -eq 0 ]
  # Extract agentMessage content from JSON envelope (after the fixed prefix)
  cursor_msg="${output#*\"agentMessage\":\"}"
  cursor_msg="${cursor_msg%\"*}"

  # Both must mention the same file and error substring
  [[ "$claude_msg" == *"src/foo.ts"* ]]
  [[ "$cursor_msg" == *"src\/foo.ts"* ]] || [[ "$cursor_msg" == *"src/foo.ts"* ]]
  [[ "$claude_msg" == *"unused variable"* ]]
  [[ "$cursor_msg" == *"unused variable"* ]]
}

# ── Host sniff fallback (no LINT_HOOK_HOST env) ────────────────────────────────

@test "payload with tool_input detected as Claude (sniff fallback)" {
  unset LINT_HOOK_HOST
  run bash "$HOOK" <<< "$(claude_payload)"
  # Claude: exit 2 + plain text
  [ "$status" -eq 2 ]
  [[ "$output" != '{"permission"'* ]]
}

@test "payload without tool_input detected as Cursor (sniff fallback)" {
  unset LINT_HOOK_HOST
  run bash "$HOOK" <<< "$(cursor_payload)"
  # Cursor: exit 0 + JSON
  [ "$status" -eq 0 ]
  [[ "$output" == '{"permission":"allow"'* ]]
}

# ── Write tool shape (Claude Write event) ─────────────────────────────────────

@test "Claude Write payload (file_path in tool_input) is handled" {
  export LINT_HOOK_HOST=claude
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="write lint error"
  payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_PROJECT/src/foo.ts"'"}}'
  run bash "$HOOK" <<< "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[lint-on-edit]"* ]]
}
