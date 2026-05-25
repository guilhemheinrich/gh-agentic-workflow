#!/usr/bin/env bash
# hooks/lint-on-edit.sh
# Spec: specs/014-lint-on-edit-hook — Contract v1.0.0
# See: specs/014-lint-on-edit-hook/contracts/hook-interface.md
#
# PostToolUse (Claude) / afterFileEdit (Cursor) hook.
# Reads the agent host's JSON payload from stdin, resolves the touched file
# to a repo-relative path, calls `make lint FILE=…`, and translates the result
# into the appropriate agent-feedback channel.
#
# Claude:  exit 2  + plain-text stdout  → routed back to model by Claude.
# Cursor:  exit 0  + JSON envelope      → agentMessage displayed in Cursor.
# Silent:  exit 0  + no stdout          → file passed / not lintable.
#
# Env knobs (all optional):
#   LINT_ON_EDIT=0      Disable unconditionally (default: 1)
#   LINT_TIMEOUT=120    Kill make after this many seconds (default: 120)
#   LINT_HOOK_HOST      "claude"|"cursor" (default: sniffed from payload)
#   LINT_DEBUG=1        Log steps to /tmp/lint-on-edit.log + stderr
#   LINT_VERBOSE=0      Forwarded to make sub-targets (default: 0)

# No 'set -e': (( )) arithmetic returns 1 when expr is 0, which is not an error.
set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
LINT_ON_EDIT="${LINT_ON_EDIT:-1}"
LINT_TIMEOUT="${LINT_TIMEOUT:-120}"
LINT_DEBUG="${LINT_DEBUG:-0}"
LINT_VERBOSE="${LINT_VERBOSE:-0}"
LOG_FILE="/tmp/lint-on-edit.log"

# Directories whose contents are never linted (silent allow, space-separated)
LINT_EXCLUDED_DIRS="node_modules/ dist/ build/ .next/ .nuxt/ .git/ .cache/ coverage/ vendor/ .venv/"

# ── Logging ──────────────────────────────────────────────────────────────────
log_debug() {
  [[ "$LINT_DEBUG" == "1" ]] || return 0
  printf '[lint-on-edit] %s\n' "$*" >&2 || true
  printf '[lint-on-edit] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# ── Exit helpers ─────────────────────────────────────────────────────────────
silent_allow() {
  log_debug "silent allow: ${1:-}"
  exit 0
}

# ── Read all stdin ────────────────────────────────────────────────────────────
read_stdin_all() {
  local content="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    content+="$line"$'\n'
  done
  printf '%s' "$content"
}

# ── Pure-Bash JSON string extraction (no jq) ─────────────────────────────────
# extract_json_string PAYLOAD KEY
# Returns the unescaped string value of the first "KEY": "..." in PAYLOAD.
extract_json_string() {
  local s="$1" key="\"$2\""
  local rest="" c="" out="" len=0 i=0

  case "$s" in
    *"$key"*) ;;
    *) printf ''; return ;;
  esac

  rest="${s#*"$key"}"
  rest="${rest#*:}"
  # Strip leading whitespace
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "$rest" == \"* ]] || { printf ''; return; }
  rest="${rest#\"}"
  out=""
  len=${#rest}
  i=0
  while (( i < len )); do
    c="${rest:i:1}"
    if [[ "$c" == '\\' ]]; then
      ((i++)) || true
      if (( i < len )); then
        out+="${rest:i:1}"
      fi
      ((i++)) || true
      continue
    fi
    [[ "$c" == '"' ]] && { printf '%s' "$out"; return; }
    out+="$c"
    ((i++)) || true
  done
  printf ''
}

# ── Extract tool_input.file_path from Claude PostToolUse payload ─────────────
extract_tool_input_file_path() {
  local s="$1"
  local rest="" out="" c=""
  local depth=0 in_str=0 len=0 i=0

  case "$s" in
    *'"tool_input"'*) ;;
    *) printf ''; return ;;
  esac

  rest="${s#*'"tool_input"'}"
  rest="${rest#*:}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "$rest" == \{* ]] || { printf ''; return; }

  out=""
  len=${#rest}
  i=0
  while (( i < len )); do
    c="${rest:i:1}"
    if (( in_str == 1 )); then
      if [[ "$c" == '\\' ]]; then
        out+="$c"
        ((i++)) || true
        if (( i < len )); then
          out+="${rest:i:1}"
        fi
        ((i++)) || true
        continue
      fi
      [[ "$c" == '"' ]] && in_str=0
      out+="$c"
    else
      [[ "$c" == '"' ]] && in_str=1
      [[ "$c" == '{' ]] && { ((depth++)) || true; out+="$c"; ((i++)) || true; continue; }
      if [[ "$c" == '}' ]]; then
        ((depth--)) || true
        out+="$c"
        ((i++)) || true
        (( depth == 0 )) && break
        continue
      fi
      out+="$c"
    fi
    ((i++)) || true
  done

  extract_json_string "$out" "file_path"
}

# ── Resolve file path from any supported payload shape ───────────────────────
resolve_file_path() {
  local payload="$1"
  local fp=""

  # 1. Claude PostToolUse: tool_input.file_path
  fp="$(extract_tool_input_file_path "$payload")"
  [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }

  # 2. Cursor / generic: file_path
  fp="$(extract_json_string "$payload" "file_path")"
  [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }

  # 3. Cursor fallback: path
  fp="$(extract_json_string "$payload" "path")"
  [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }

  # 4. Cursor fallback: file
  fp="$(extract_json_string "$payload" "file")"
  [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }

  printf ''
}

# ── Host detection ────────────────────────────────────────────────────────────
detect_host() {
  local payload="$1"

  if [[ -n "${LINT_HOOK_HOST:-}" ]]; then
    printf '%s' "$LINT_HOOK_HOST"
    return
  fi

  # Sniff: Claude payloads contain "tool_input"; Cursor payloads do not.
  case "$payload" in
    *'"tool_input"'*) printf 'claude' ;;
    *)                printf 'cursor' ;;
  esac
}

# ── JSON escape for Cursor agentMessage ──────────────────────────────────────
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ── Emit agent feedback to the appropriate host ───────────────────────────────
emit_feedback() {
  local host="$1" msg="$2"

  if [[ "$host" == "claude" ]]; then
    printf '%s\n' "$msg"
    exit 2
  else
    local escaped
    escaped="$(json_escape "$msg")"
    printf '{"permission":"allow","continue":true,"agentMessage":"%s"}\n' "$escaped"
    exit 0
  fi
}

# ── Check if path is under an excluded directory ─────────────────────────────
is_excluded_path() {
  local rel="$1" dir
  for dir in $LINT_EXCLUDED_DIRS; do
    case "$rel" in
      "$dir"*) return 0 ;;
    esac
  done
  return 1
}

# ── Find project root (ancestor dir containing a Makefile) ───────────────────
find_project_root() {
  local start_dir="$1" dir git_root
  dir="$start_dir"

  # Prefer git root if it also has a Makefile
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || true
    if [[ -n "$git_root" && -f "$git_root/Makefile" ]]; then
      printf '%s' "$git_root"
      return
    fi
  fi

  # Walk up from start_dir
  while [[ "$dir" != "/" ]]; do
    [[ -f "$dir/Makefile" ]] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done

  printf ''
}

# ── Run `make lint` with timeout, capture output and exit code ────────────────
run_make_lint() {
  local project_root="$1" rel_path="$2"
  local tmp_out make_exit=0 sentinel

  tmp_out="$(mktemp /tmp/lint-on-edit-XXXXXX)"
  sentinel="/tmp/lint-on-edit-timeout-$$"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$LINT_TIMEOUT" make -C "$project_root" lint FILE="$rel_path" \
      LINT_VERBOSE="$LINT_VERBOSE" >"$tmp_out" 2>&1 || make_exit=$?
  else
    # Pure-Bash fallback: background process + sleep killer
    make -C "$project_root" lint FILE="$rel_path" \
      LINT_VERBOSE="$LINT_VERBOSE" >"$tmp_out" 2>&1 &
    local make_pid=$!
    (
      sleep "$LINT_TIMEOUT"
      kill "$make_pid" 2>/dev/null && touch "$sentinel"
    ) &
    local timer_pid=$!
    wait "$make_pid" 2>/dev/null || make_exit=$?
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
    if [[ -f "$sentinel" ]]; then
      rm -f "$sentinel"
      make_exit=124
    fi
  fi

  cat "$tmp_out"
  rm -f "$tmp_out"
  return "$make_exit"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Respect LINT_ON_EDIT=0 kill-switch
[[ "$LINT_ON_EDIT" == "0" ]] && silent_allow "LINT_ON_EDIT=0"

# Guard against direct invocation without stdin payload
if [[ -t 0 ]]; then
  printf 'Usage: echo <json-payload> | %s\n' "$0" >&2
  printf 'Set LINT_ON_EDIT=0 to disable.\n' >&2
  exit 1
fi

raw_input="$(read_stdin_all)"
[[ -z "${raw_input//[$'\t\n\r ']/}" ]] && silent_allow "empty stdin"

log_debug "payload (first 200): ${raw_input:0:200}"

file_path="$(resolve_file_path "$raw_input")"
[[ -z "$file_path" ]] && silent_allow "no file path found in payload"

log_debug "file_path: $file_path"

host="$(detect_host "$raw_input")"
log_debug "host: $host"

# Determine the directory to start searching from
if [[ "$file_path" == /* ]]; then
  file_dir="$(dirname "$file_path")"
else
  file_dir="$(pwd)"
fi

project_root="$(find_project_root "$file_dir")"
[[ -z "$project_root" ]] && silent_allow "no Makefile found in ancestors of $file_path"

log_debug "project_root: $project_root"

# Verify file is within project root; resolve relative path
if [[ "$file_path" == /* ]]; then
  case "$file_path" in
    "$project_root/"*) ;;
    *) silent_allow "file outside project root: $file_path" ;;
  esac
  rel_path="${file_path#"$project_root/"}"
else
  rel_path="$file_path"
fi

log_debug "rel_path: $rel_path"

# File must exist on disk (skip deleted files)
[[ -f "$project_root/$rel_path" ]] || silent_allow "file does not exist: $rel_path"

# Skip files under excluded directories
is_excluded_path "$rel_path" && silent_allow "excluded path: $rel_path"

# Extract file extension
filename="${rel_path##*/}"
ext="${filename##*.}"
[[ "$ext" != "$filename" ]] && ext=".$ext" || ext=""

log_debug "ext: $ext"

# Run lint and capture output + exit code
make_output=""
make_exit=0
make_output="$(run_make_lint "$project_root" "$rel_path")" || make_exit=$?

log_debug "make_exit: $make_exit, output (first 200): ${make_output:0:200}"

# Lint passed — silent
[[ "$make_exit" == "0" ]] && silent_allow "lint passed"

# Lint timed out
if [[ "$make_exit" == "124" ]]; then
  emit_feedback "$host" "[lint-on-edit] file=$rel_path ext=$ext target=lint code=124

Lint timed out after ${LINT_TIMEOUT}s. The container may be cold or hung.
Consider raising LINT_TIMEOUT or running: make up"
fi

# Map exit code to a meaningful target label for the header
case "$make_exit" in
  64) target_label="none" ;;
  *)  target_label="lint-${ext#.}" ;;
esac

msg="[lint-on-edit] file=$rel_path ext=$ext target=$target_label code=$make_exit

$make_output"

emit_feedback "$host" "$msg"
