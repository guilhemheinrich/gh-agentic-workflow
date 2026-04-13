#!/usr/bin/env bash
# Cursor beforeShellExecution hook: suggest modern CLI tools (pure Bash, no jq).

# No 'set -e': arithmetic (( )) and while (( )) can exit 1 without being errors.
set -uo pipefail

log_debug() { printf '%s\n' "$*" >&2 || true; }

allow() {
  printf '%s\n' '{"permission":"allow","continue":true}'
  exit 0
}

deny() {
  local msg="$1"
  local esc=""
  esc="${msg//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"
  esc="${esc//$'\r'/\\r}"
  esc="${esc//$'\t'/\\t}"
  printf '{"permission":"deny","continue":true,"agentMessage":"%s"}\n' "$esc"
  exit 0
}

read_stdin_all() {
  local content=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    content+="$line"$'\n'
  done
  printf '%s' "$content"
}

# Extract JSON string value for "command" (handles \" and \\ inside the string).
extract_command_field() {
  local s="$1"
  local key='"command"'
  local rest c i out len

  case "$s" in
    *"$key"*) ;;
    *) printf ''; return ;;
  esac

  rest="${s#*"$key"}"
  rest="${rest#*:}"
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
    if [[ "$c" == '"' ]]; then
      printf '%s' "$out"
      return
    fi
    out+="$c"
    ((i++)) || true
  done
  printf ''
}

has_word() {
  local cmd="$1" word="$2"
  [[ "$cmd" =~ (^|[^a-zA-Z0-9_])${word}([^a-zA-Z0-9_]|$) ]]
}

# --- Rule 1: grep family → rg ---
rule_grep_deny() {
  command -v rg >/dev/null 2>&1 || return 1
  [[ -z "$cmd" ]] && return 1

  [[ "$cmd" == *--version* ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])which[[:space:]]+grep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])which[[:space:]]+egrep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])which[[:space:]]+fgrep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])command[[:space:]]+-v[[:space:]]+grep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])command[[:space:]]+-v[[:space:]]+egrep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])command[[:space:]]+-v[[:space:]]+fgrep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])type[[:space:]]+grep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])type[[:space:]]+egrep([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])type[[:space:]]+fgrep([^a-zA-Z0-9_]|$) ]] && return 1

  if has_word "$cmd" egrep || has_word "$cmd" fgrep || has_word "$cmd" grep; then
    return 0
  fi
  return 1
}

# --- Rule 2: find + path-like start → fd ---
rule_find_deny() {
  command -v fd >/dev/null 2>&1 || return 1
  [[ -z "$cmd" ]] && return 1

  [[ "$cmd" == *--version* ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])command[[:space:]]+-v[[:space:]]+find([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])which[[:space:]]+find([^a-zA-Z0-9_]|$) ]] && return 1
  [[ "$cmd" =~ (^|[;|&[:space:]])type[[:space:]]+find([^a-zA-Z0-9_]|$) ]] && return 1

  has_word "$cmd" find || return 1

  if [[ "$cmd" =~ find[[:space:]]+\.[[:space:]] ]] \
    || [[ "$cmd" =~ find[[:space:]]+\./ ]] \
    || [[ "$cmd" =~ find[[:space:]]+\.\./ ]] \
    || [[ "$cmd" =~ find[[:space:]]+~ ]] \
    || [[ "$cmd" =~ find[[:space:]]+/ ]]; then
    return 0
  fi
  return 1
}

# --- Rule 3: simple cat file read → bat ---
rule_cat_deny() {
  command -v bat >/dev/null 2>&1 || return 1
  [[ -z "$cmd" ]] && return 1

  has_word "$cmd" cat || return 1
  # Cannot inline << inside [[ =~ ]] (parsed as heredoc); use regex variable.
  local _re_cat_heredoc='cat[[:space:]]*<<'
  [[ "$cmd" =~ $_re_cat_heredoc ]] && return 1
  if [[ "$cmd" =~ cat ]]; then
    local after="${cmd#*cat}"
    after="${after#"${after%%[![:space:]]*}"}"
    [[ "$after" == '>'* || "$after" == '>>'* ]] && return 1
  fi
  [[ "$cmd" =~ cat[^[:space:]]*[[:space:]]*\> ]] && return 1
  [[ "$cmd" =~ \>[[:space:]]*cat ]] && return 1

  return 0
}

# --- Rule 4: python/node JSON one-liners + .json → jq ---
rule_jq_deny() {
  command -v jq >/dev/null 2>&1 || return 1
  [[ -z "$cmd" ]] && return 1

  [[ "$cmd" != *.json* ]] && return 1

  if [[ "$cmd" =~ (python3|python)[[:space:]].*-c ]]; then
    if [[ "$cmd" == *import[[:space:]]json* || "$cmd" == *json.load* || "$cmd" == *json.loads* ]]; then
      return 0
    fi
  fi

  if [[ "$cmd" =~ node[[:space:]].*(-e|--eval) ]]; then
    if [[ "$cmd" == *JSON.parse* || "$cmd" == *JSON.stringify* ]]; then
      return 0
    fi
  fi

  return 1
}

raw_input="$(read_stdin_all)"
if [[ -z "${raw_input//[$'\t\n\r ']/}" ]]; then
  log_debug "[enforce-tools] empty stdin → allow"
  allow
fi

cmd="$(extract_command_field "$raw_input")"
if [[ -z "$cmd" ]]; then
  log_debug "[enforce-tools] missing or unparseable command field → allow"
  allow
fi

log_debug "[enforce-tools] command: ${cmd:0:200}"

if rule_grep_deny; then
  deny "Use \`rg\` (ripgrep) instead of \`grep\`. It is faster and respects .gitignore.
Examples:
- grep -r 'pattern' . → rg 'pattern'
- grep -rn 'pattern' --include='*.ts' → rg 'pattern' -t ts
- grep -l 'pattern' → rg -l 'pattern'"
fi

if rule_find_deny; then
  deny "Use \`fd\` instead of \`find\`. It is faster and respects .gitignore.
Examples:
- find . -name '*.ts' → fd -e ts
- find . -type f -name '*.json' → fd -e json
- find /path -name 'foo*' → fd 'foo' /path"
fi

if rule_cat_deny; then
  deny "Use \`bat\` instead of \`cat\` for file viewing. It provides syntax highlighting.
Examples:
- cat src/main.ts → bat src/main.ts
- cat -n file.txt → bat -n file.txt"
fi

if rule_jq_deny; then
  deny "Use \`jq\` for JSON processing instead of python/node one-liners.
Examples:
- cat file.json | python -c 'import json...' → jq '.' file.json
- python -c 'json.load(...)' → jq '.field' file.json"
fi

allow
