#!/usr/bin/env bats
# tests/hooks/lint_on_edit.bats
# Unit tests for hooks/lint-on-edit.sh
#
# Run via: make test-hooks
# Or directly: docker run --rm -v $(pwd):/workspace -w /workspace bats/bats:latest tests/hooks/

HOOK="$BATS_TEST_DIRNAME/../../hooks/lint-on-edit.sh"
STUB_MAKE_DIR="$BATS_TEST_DIRNAME/fixtures/stub-make"

# ── Helpers ────────────────────────────────────────────────────────────────────

setup() {
  # Create a temporary project directory with a real file and a Makefile stub.
  TEST_PROJECT="$(mktemp -d)"
  mkdir -p "$TEST_PROJECT/src"
  echo 'const x = 1;' > "$TEST_PROJECT/src/foo.ts"
  echo 'Hello world' > "$TEST_PROJECT/README.md"
  # An empty Makefile is enough — the hook only checks for its existence to
  # locate the project root; the real `make` invocation goes through the
  # stub-make binary placed first on PATH below.
  : >"$TEST_PROJECT/Makefile"

  # Put stub-make first on PATH so the hook calls our stub make, not the real one.
  export PATH="$STUB_MAKE_DIR:$PATH"

  # Default env: Claude host, lint enabled, short timeout, no debug.
  export LINT_HOOK_HOST=claude
  export LINT_ON_EDIT=1
  export LINT_TIMEOUT=10
  export LINT_DEBUG=0

  # Default stub behavior: pass (exit 0, no output).
  export STUB_MAKE_EXIT=0
  export STUB_MAKE_OUTPUT=""

  chmod +x "$STUB_MAKE_DIR/make"
}

teardown() {
  rm -rf "$TEST_PROJECT"
}

# Build a Claude PostToolUse payload for a file in TEST_PROJECT.
claude_payload() {
  local file="$1"
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' \
    "$TEST_PROJECT/$file" "$TEST_PROJECT"
}

# Build a Cursor afterFileEdit payload for a file in TEST_PROJECT.
cursor_payload() {
  local file="$1"
  printf '{"event":"afterFileEdit","file_path":"%s","workspace_folder":"%s"}' \
    "$TEST_PROJECT/$file" "$TEST_PROJECT"
}

# ── LINT_ON_EDIT=0 kill-switch ─────────────────────────────────────────────────

@test "LINT_ON_EDIT=0 exits silently regardless of payload" {
  export LINT_ON_EDIT=0
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Empty / unrecognised payload ───────────────────────────────────────────────

@test "empty stdin exits silently" {
  run bash "$HOOK" <<< ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unrecognised payload shape exits silently" {
  run bash "$HOOK" <<< '{"event":"someOtherEvent","data":{}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Claude — passing lint ──────────────────────────────────────────────────────

@test "claude — passing lint exits 0 with no output" {
  export STUB_MAKE_EXIT=0
  export STUB_MAKE_OUTPUT=""
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Claude — failing lint ──────────────────────────────────────────────────────

@test "claude — failing lint exits 2 and emits diagnostic" {
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="src/foo.ts:1:7  error  'x' is assigned a value but never used  no-unused-vars"
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[lint-on-edit]"* ]]
  [[ "$output" == *"src/foo.ts"* ]]
  [[ "$output" == *"no-unused-vars"* ]]
}

@test "claude — failing lint header contains file, ext, target, code" {
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="some lint error"
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"file=src/foo.ts"* ]]
  [[ "$output" == *"ext=.ts"* ]]
  [[ "$output" == *"code=1"* ]]
}

# ── Cursor — passing lint ──────────────────────────────────────────────────────

@test "cursor — passing lint exits 0 with no output" {
  export LINT_HOOK_HOST=cursor
  export STUB_MAKE_EXIT=0
  export STUB_MAKE_OUTPUT=""
  run bash "$HOOK" <<< "$(cursor_payload "src/foo.ts")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Cursor — failing lint ──────────────────────────────────────────────────────

@test "cursor — failing lint exits 0 with JSON envelope containing agentMessage" {
  export LINT_HOOK_HOST=cursor
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="src/foo.ts:1 error unused variable"
  run bash "$HOOK" <<< "$(cursor_payload "src/foo.ts")"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"permission":"allow","continue":true,"agentMessage":"'* ]]
  [[ "$output" == *"[lint-on-edit]"* ]]
  [[ "$output" == *"src/foo.ts"* ]]
}

@test "cursor — agentMessage is valid JSON (no bare newlines)" {
  export LINT_HOOK_HOST=cursor
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="line one
line two"
  run bash "$HOOK" <<< "$(cursor_payload "src/foo.ts")"
  [ "$status" -eq 0 ]
  # Output must be a single line (no raw newlines in JSON string)
  [ "$(echo "$output" | wc -l)" -eq 1 ]
  # Real newlines must have been escaped to literal "\n" sequences inside the
  # JSON string. Use double-quoted pattern (Alpine bash differs from macOS
  # bash on how it handles single-quoted backslashes inside [[ patterns).
  [[ "$output" == *"\\n"* ]]
}

# ── Policy gap (exit 64) ───────────────────────────────────────────────────────

@test "claude — policy gap for unknown extension exits 2 with 'policy gap' phrase" {
  export STUB_MAKE_EXIT=64
  export STUB_MAKE_OUTPUT="lint router: extension '.xyz' is neither routed nor ignored."
  touch "$TEST_PROJECT/src/foo.xyz"
  run bash "$HOOK" <<< "$(claude_payload "src/foo.xyz")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"code=64"* ]]
}

@test "cursor — policy gap for unknown extension emits JSON agentMessage" {
  export LINT_HOOK_HOST=cursor
  export STUB_MAKE_EXIT=64
  export STUB_MAKE_OUTPUT="lint router: extension '.xyz' is neither routed nor ignored."
  touch "$TEST_PROJECT/src/foo.xyz"
  run bash "$HOOK" <<< "$(cursor_payload "src/foo.xyz")"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"permission":"allow","continue":true,"agentMessage":"'* ]]
  [[ "$output" == *"code=64"* ]]
}

# ── File outside project root ──────────────────────────────────────────────────

@test "file path outside project root exits silently" {
  # /tmp/outside.ts is not under TEST_PROJECT
  payload='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/outside-test-$$.ts"},"cwd":"'"$TEST_PROJECT"'"}'
  run bash "$HOOK" <<< "$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Excluded paths ─────────────────────────────────────────────────────────────

@test "file under node_modules/ exits silently" {
  mkdir -p "$TEST_PROJECT/node_modules/@types"
  echo 'declare const x: string;' > "$TEST_PROJECT/node_modules/@types/foo.d.ts"
  payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_PROJECT/node_modules/@types/foo.d.ts"'"}}'
  run bash "$HOOK" <<< "$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Host detection by payload sniff ───────────────────────────────────────────

@test "host sniff: payload with tool_input detected as claude" {
  unset LINT_HOOK_HOST
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="some error"
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  # Claude response: exit 2 (plain text)
  [ "$status" -eq 2 ]
}

@test "host sniff: payload without tool_input detected as cursor" {
  unset LINT_HOOK_HOST
  export STUB_MAKE_EXIT=1
  export STUB_MAKE_OUTPUT="some error"
  run bash "$HOOK" <<< "$(cursor_payload "src/foo.ts")"
  # Cursor response: exit 0 + JSON
  [ "$status" -eq 0 ]
  [[ "$output" == '{"permission":"allow"'* ]]
}

# ── Wiring missing (exit 65) ───────────────────────────────────────────────────

@test "claude — wiring missing exit 65 surfaces agent message" {
  export STUB_MAKE_EXIT=65
  export STUB_MAKE_OUTPUT="lint-ts: biome not found; wire up the linter"
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"code=65"* ]]
  [[ "$output" == *"biome not found"* ]]
}

# ── Timeout ───────────────────────────────────────────────────────────────────

@test "LINT_ON_EDIT=0 bypasses make entirely (timeout not relevant)" {
  export LINT_ON_EDIT=0
  export LINT_TIMEOUT=1
  run bash "$HOOK" <<< "$(claude_payload "src/foo.ts")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
