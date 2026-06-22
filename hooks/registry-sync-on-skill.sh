#!/usr/bin/env bash
# hooks/registry-sync-on-skill.sh
#
# PostToolUse (Claude) / afterFileEdit (Cursor) hook.
# Fires when a SKILL.md is created or edited. Resolves the skill's directory
# to a repo-relative path and checks whether asset-registry.yml already has an
# entry for it. If not, it reminds the agent (per AGENTS.md) to register the
# skill in the same change. If already registered, it stays silent.
#
# This is a *reminder* hook, not a validator: it never rewrites the registry.
#
# Claude:  exit 2  + plain-text stdout  → routed back to model by Claude.
# Cursor:  exit 0  + JSON envelope      → agentMessage displayed in Cursor.
# Silent:  exit 0  + no stdout          → not a SKILL.md / already registered.
#
# Env knobs (all optional):
#   REGISTRY_SYNC=0       Disable unconditionally (default: 1)
#   REGISTRY_FILE         Registry filename (default: asset-registry.yml)
#   REGISTRY_HOOK_HOST    "claude"|"cursor" (default: sniffed from payload)
#   REGISTRY_DEBUG=1      Log steps to /tmp/registry-sync.log + stderr

set -uo pipefail

REGISTRY_SYNC="${REGISTRY_SYNC:-1}"
REGISTRY_FILE="${REGISTRY_FILE:-asset-registry.yml}"
REGISTRY_DEBUG="${REGISTRY_DEBUG:-0}"
LOG_FILE="/tmp/registry-sync.log"

# ── Logging ──────────────────────────────────────────────────────────────────
log_debug() {
  [[ "$REGISTRY_DEBUG" == "1" ]] || return 0
  printf '[registry-sync] %s\n' "$*" >&2 || true
  printf '[registry-sync] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

silent_allow() {
  log_debug "silent allow: ${1:-}"
  exit 0
}

# ── Read all stdin ─────────────────────────────────────────────────────────────
read_stdin_all() {
  local content="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    content+="$line"$'\n'
  done
  printf '%s' "$content"
}

# ── Pure-Bash JSON string extraction (no jq) ─────────────────────────────────
extract_json_string() {
  local s="$1" key="\"$2\""
  local rest="" c="" out="" len=0 i=0

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
  local payload="$1" fp=""
  fp="$(extract_tool_input_file_path "$payload")"; [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }
  fp="$(extract_json_string "$payload" "file_path")"; [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }
  fp="$(extract_json_string "$payload" "path")";      [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }
  fp="$(extract_json_string "$payload" "file")";      [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }
  printf ''
}

# ── Host detection ────────────────────────────────────────────────────────────
detect_host() {
  local payload="$1"
  if [[ -n "${REGISTRY_HOOK_HOST:-}" ]]; then printf '%s' "$REGISTRY_HOOK_HOST"; return; fi
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

# ── Path helpers (cross-platform: Windows drive letters & MSYS forms) ────────
# Normalize for comparison: backslashes → slashes, "D:/x" → "/d/x", lowercase drive.
normalize_path() {
  local p="$1"
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
    local drive
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"
    p="/$drive/${BASH_REMATCH[2]}"
  fi
  printf '%s' "$p"
}

# A path is absolute if it starts with "/" or a "C:" / "C:\" drive prefix.
is_absolute_path() {
  case "$1" in
    /*) return 0 ;;
    [A-Za-z]:[/\\]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Find repo root (ancestor dir containing the registry file) ───────────────
find_repo_root() {
  local start_dir="$1" dir git_root
  dir="$start_dir"

  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || true
    if [[ -n "$git_root" && -f "$git_root/$REGISTRY_FILE" ]]; then
      printf '%s' "$git_root"; return
    fi
  fi

  while [[ "$dir" != "/" ]]; do
    [[ -f "$dir/$REGISTRY_FILE" ]] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done
  printf ''
}

# ── Main ──────────────────────────────────────────────────────────────────────

[[ "$REGISTRY_SYNC" == "0" ]] && silent_allow "REGISTRY_SYNC=0"

if [[ -t 0 ]]; then
  printf 'Usage: echo <json-payload> | %s\n' "$0" >&2
  printf 'Set REGISTRY_SYNC=0 to disable.\n' >&2
  exit 1
fi

raw_input="$(read_stdin_all)"
[[ -z "${raw_input//[$'\t\n\r ']/}" ]] && silent_allow "empty stdin"

log_debug "payload (first 200): ${raw_input:0:200}"

file_path="$(resolve_file_path "$raw_input")"
[[ -z "$file_path" ]] && silent_allow "no file path found in payload"

# Normalize separators up front so Windows paths (D:\a\b\SKILL.md) match the
# same patterns as POSIX paths everywhere below.
file_path="${file_path//\\//}"

# Only react to SKILL.md files.
case "$file_path" in
  */SKILL.md|SKILL.md) ;;
  *) silent_allow "not a SKILL.md: $file_path" ;;
esac

host="$(detect_host "$raw_input")"
log_debug "host=$host file_path=$file_path"

# Determine where to start searching for the repo root.
if is_absolute_path "$file_path"; then
  file_dir="$(dirname "$file_path")"
else
  file_dir="$(pwd)"
fi

repo_root="$(find_repo_root "$file_dir")"
[[ -z "$repo_root" ]] && silent_allow "no $REGISTRY_FILE found in ancestors of $file_path"

# Resolve the SKILL.md to a repo-relative path. Compare in normalized form to
# absorb Windows/MSYS differences (D:/x vs /d/x, backslashes), but keep the
# original repo_root for filesystem access.
if is_absolute_path "$file_path"; then
  norm_root="$(normalize_path "$repo_root")"
  norm_file="$(normalize_path "$file_path")"
  case "$norm_file" in
    "$norm_root/"*) ;;
    *) silent_allow "file outside repo root: $file_path" ;;
  esac
  rel_path="${norm_file#"$norm_root/"}"
else
  rel_path="$file_path"
fi

# Skill must still exist on disk (ignore deletions).
[[ -f "$repo_root/$rel_path" ]] || silent_allow "skill file does not exist: $rel_path"

# The registry references the skill DIRECTORY with a trailing slash.
skill_dir="${rel_path%/SKILL.md}"
[[ "$skill_dir" == "$rel_path" ]] && skill_dir=""   # top-level SKILL.md (no dir)
registry="$repo_root/$REGISTRY_FILE"

log_debug "skill_dir=$skill_dir registry=$registry"

# Already registered? Match `path: <skill_dir>/` literally (allow optional quotes).
if [[ -n "$skill_dir" ]]; then
  if grep -Eq "path:[[:space:]]+[\"']?${skill_dir}/[\"']?[[:space:]]*\$" "$registry" 2>/dev/null; then
    silent_allow "already registered: $skill_dir/"
  fi
fi

skill_name="${skill_dir##*/}"
[[ -z "$skill_name" ]] && skill_name="<skill>"

msg="[registry-sync] file=$rel_path
Skill \"$skill_name\" is not yet in $REGISTRY_FILE.

Per AGENTS.md, register it in the SAME change. Add under \`assets:\`:

- path: $skill_dir/
  type: skill
  tags:
  - <tag>            # must exist in x-tag-descriptions; if missing, add it to
                     # asset-registry.yml AND the \`tag\` enum in asset-registry.schema.json
  description: <reuse the SKILL.md frontmatter description>
  category: <one of x-category-descriptions>
  # bundles: [common]   # only if part of the stack-agnostic starter set

After editing, confirm the registry has no schema diagnostics."

emit_feedback "$host" "$msg"
