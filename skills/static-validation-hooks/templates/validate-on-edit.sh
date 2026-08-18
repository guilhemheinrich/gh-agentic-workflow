#!/usr/bin/env bash
# .agents/hooks/validate-on-edit.sh
#
# Static-validation hook. Runs after every agent file edit, routes the touched
# file to a fast file-local linter inside an ALREADY-RUNNING compose container,
# and stays silent unless something is wrong.
#
# Two layers live in this file:
#   1. The RUNNER (everything above the ROUTING TABLE) — generic, copy as-is.
#      Owns the agent protocol, container resolution, time budget, retry brake.
#   2. The ROUTING TABLE (between the BEGIN/END markers) — project-specific.
#      This is the only part you edit. See skills/static-validation-hooks.
#
# Agent protocol:
#   Claude  violations -> stderr + exit 2  (Claude feeds stderr back to the model)
#   Cursor  violations -> stdout JSON + exit 0
#   Silent  everything else -> exit 0, no output
#
# Env knobs (all optional):
#   VALIDATE_ON_EDIT=0      Kill-switch. Default 1.
#   VALIDATE_BUDGET_S=3     Hard wall-clock cap per command. Default 3.
#   VALIDATE_MAX_RETRIES=3  Consecutive rejections on one file before muting it.
#   VALIDATE_MUTE_TTL_S=900 How long a muted file stays muted. Default 900.
#   VALIDATE_WORKTREE=auto  auto|skip|run — behaviour inside a linked worktree.
#   VALIDATE_HOST           claude|cursor — force the response shape.
#   VALIDATE_DEBUG=1        Verbose trace to stderr and the log file.
#
# CLI (for humans, not the agent):
#   validate-on-edit.sh --dry-run <path>   Show routing decision, run nothing.
#   validate-on-edit.sh --check <path>     Run the real validation, print timing.
#   validate-on-edit.sh --doctor           Check docker + services + warnings.

# No 'set -e': (( )) returns 1 on a zero result, which is not an error here.
set -uo pipefail

VALIDATE_ON_EDIT="${VALIDATE_ON_EDIT:-1}"
VALIDATE_BUDGET_S="${VALIDATE_BUDGET_S:-3}"
VALIDATE_MAX_RETRIES="${VALIDATE_MAX_RETRIES:-3}"
VALIDATE_MUTE_TTL_S="${VALIDATE_MUTE_TTL_S:-900}"
VALIDATE_WORKTREE="${VALIDATE_WORKTREE:-auto}"
VALIDATE_DEBUG="${VALIDATE_DEBUG:-0}"

LOG_FILE="${TMPDIR:-/tmp}/validate-on-edit.log"

# Directories never validated (silent allow).
EXCLUDED_DIRS="node_modules/ dist/ build/ out/ .next/ .nuxt/ .output/ .git/ .cache/ coverage/ vendor/ .venv/ __pycache__/ .mypy_cache/ .ruff_cache/ .turbo/"

# ── Logging ──────────────────────────────────────────────────────────────────
log() {
  printf '[validate %s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG_FILE" 2>/dev/null || true
  [[ "$VALIDATE_DEBUG" == "1" ]] && printf '[validate] %s\n' "$*" >&2
  return 0
}

silent() { log "silent: ${1:-}"; exit 0; }

# ── Pure-Bash JSON string extraction (no jq dependency) ──────────────────────
extract_json_string() {
  local s="$1" key="\"$2\"" rest="" c="" out="" len=0 i=0
  case "$s" in *"$key"*) ;; *) printf ''; return ;; esac
  rest="${s#*"$key"}"
  rest="${rest#*:}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "$rest" == \"* ]] || { printf ''; return; }
  rest="${rest#\"}"
  len=${#rest}
  while (( i < len )); do
    c="${rest:i:1}"
    if [[ "$c" == '\\' ]]; then
      ((i++)) || true
      (( i < len )) && out+="${rest:i:1}"
      ((i++)) || true
      continue
    fi
    [[ "$c" == '"' ]] && { printf '%s' "$out"; return; }
    out+="$c"
    ((i++)) || true
  done
  printf ''
}

# Claude nests the path under tool_input; walk that object first.
extract_tool_input_file_path() {
  local s="$1" rest="" out="" c="" depth=0 in_str=0 len=0 i=0
  case "$s" in *'"tool_input"'*) ;; *) printf ''; return ;; esac
  rest="${s#*'"tool_input"'}"
  rest="${rest#*:}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "$rest" == \{* ]] || { printf ''; return; }
  len=${#rest}
  while (( i < len )); do
    c="${rest:i:1}"
    if (( in_str == 1 )); then
      if [[ "$c" == '\\' ]]; then
        out+="$c"; ((i++)) || true
        (( i < len )) && out+="${rest:i:1}"
        ((i++)) || true; continue
      fi
      [[ "$c" == '"' ]] && in_str=0
      out+="$c"
    else
      [[ "$c" == '"' ]] && in_str=1
      [[ "$c" == '{' ]] && { ((depth++)) || true; out+="$c"; ((i++)) || true; continue; }
      if [[ "$c" == '}' ]]; then
        ((depth--)) || true; out+="$c"; ((i++)) || true
        (( depth == 0 )) && break
        continue
      fi
      out+="$c"
    fi
    ((i++)) || true
  done
  extract_json_string "$out" "file_path"
}

resolve_file_path() {
  local payload="$1" fp=""
  fp="$(extract_tool_input_file_path "$payload")"; [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }
  for k in file_path path file; do
    fp="$(extract_json_string "$payload" "$k")"; [[ -n "$fp" ]] && { printf '%s' "$fp"; return; }
  done
  printf ''
}

detect_host() {
  [[ -n "${VALIDATE_HOST:-}" ]] && { printf '%s' "$VALIDATE_HOST"; return; }
  case "$1" in
    *'"tool_input"'*) printf 'claude' ;;
    *)                printf 'cursor' ;;
  esac
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Claude reads stderr on exit 2; Cursor reads a JSON envelope on exit 0.
emit_feedback() {
  local msg="$1"
  if [[ "$HOST" == "claude" ]]; then
    printf '%s\n' "$msg" >&2
    exit 2
  fi
  printf '{"permission":"allow","continue":true,"agentMessage":"%s"}\n' "$(json_escape "$msg")"
  exit 0
}

# ── State (bash 3.2 compatible: files, not associative arrays) ────────────────
state_key() { printf '%s' "$1" | cksum | tr -d ' \n'; }

state_init() {
  STATE_DIR="${TMPDIR:-/tmp}/validate-on-edit/$(state_key "$PROJECT_ROOT")"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

# Warn the agent about a given condition at most once per session.
# NOTE: `id` must be assigned before it is used — a single `local a=1 b="$a"`
# expands every word before the assignments happen, so $a would be unbound.
warn_once() {
  local id="$1" msg="$2"
  local sentinel="$STATE_DIR/warn-$(state_key "$id")"
  [[ -f "$sentinel" ]] && { log "warn suppressed: $id"; return 1; }
  : >"$sentinel"
  WARNING="$msg"
  return 0
}

file_age_s() {
  local f="$1" mt=""
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || return 1
  printf '%s' "$(( $(date +%s) - mt ))"
}

# ── Time budget (portable: GNU timeout, gtimeout, or a bash watchdog) ─────────
TIMEOUT_BIN=""
for c in timeout gtimeout; do
  command -v "$c" >/dev/null 2>&1 && { TIMEOUT_BIN="$c"; break; }
done

# The budget is per EDIT, not per command: a branch running three linters must
# still return inside VALIDATE_BUDGET_S. _DEADLINE is armed by validate_path.
_DEADLINE=0
BUDGET_OUT=""

remaining_budget() {
  local left=$(( _DEADLINE - $(date +%s) ))
  (( left < 0 )) && left=0
  printf '%s' "$left"
}

# Output goes to a file, never to a command substitution: killing the direct
# child does not close a pipe its own descendants still hold open, so `$( )`
# would block for the full runtime of a grandchild and the budget would be a
# lie. Returns the command's exit code, or 124 when the budget ran out.
with_budget() {
  local left; left="$(remaining_budget)"
  BUDGET_OUT="$(mktemp "${TMPDIR:-/tmp}/validate-out-XXXXXX")"
  (( left <= 0 )) && return 124

  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$left" "$@" >"$BUDGET_OUT" 2>&1
    return $?
  fi

  local sentinel="${BUDGET_OUT}.killed" rc=0 pid timer
  "$@" >"$BUDGET_OUT" 2>&1 </dev/null &
  pid=$!
  # The watchdog MUST NOT inherit stdout: callers wrap this in `$( )`, and a
  # sleeping grandchild holding that pipe open makes the substitution block for
  # the whole budget even when the command already returned.
  ( sleep "$left"; kill -9 "$pid" 2>/dev/null && : >"$sentinel" ) >/dev/null 2>&1 </dev/null &
  timer=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  [[ -f "$sentinel" ]] && { rm -f "$sentinel"; return 124; }
  return "$rc"
}

# ── Container resolution (cached; the hot path is a single `docker exec`) ─────
compose_project() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then printf '%s' "$COMPOSE_PROJECT_NAME"; return; fi
  basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

lookup_cid() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$(compose_project)" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -n1
}

# exec_in SERVICE CMD... — stdout+stderr merged on stdout, container rc returned.
# 125 = no running container (or docker unusable), 124 = budget exceeded.
drain_budget_out() {
  [[ -n "$BUDGET_OUT" && -f "$BUDGET_OUT" ]] || return 0
  cat "$BUDGET_OUT"
  rm -f "$BUDGET_OUT"
}

exec_in() {
  local svc="$1"; shift
  local cache="$STATE_DIR/cid-$svc" cid="" rc=0

  [[ -f "$cache" ]] && cid="$(cat "$cache" 2>/dev/null)"

  # Hot path: one `docker exec` on the cached container id, no lookup at all.
  if [[ -n "$cid" ]]; then
    with_budget docker exec -i "$cid" "$@"; rc=$?
    if (( rc != 125 )); then drain_budget_out; return "$rc"; fi
    log "stale cid for $svc, re-resolving"
    rm -f "$BUDGET_OUT" "$cache"
  fi

  cid="$(lookup_cid "$svc")"
  [[ -z "$cid" ]] && return 125
  printf '%s' "$cid" >"$cache" 2>/dev/null || true

  with_budget docker exec -i "$cid" "$@"; rc=$?
  drain_budget_out
  return "$rc"
}

# ── Routing verbs — the vocabulary the ROUTING TABLE is written in ───────────
#   svc NAME       target compose service (required, first)
#   strip PREFIX   drop a path prefix so the container sees its own relative path
#   fix  CMD...    best-effort auto-fix; failures never reach the agent
#   check CMD...   validation; a non-zero exit becomes agent feedback
#   skip           explicitly declare this path as not validated
_SVC=""; _SKIP=0; _ROUTED=0; _VIOLATION=""; F=""; REL=""; WARNING=""; DRY=0

svc()   { _SVC="$1"; _ROUTED=1; F="${F:-$REL}"; }
strip() { F="${REL#$1}"; }
skip()  { _SKIP=1; _ROUTED=1; }

# Shared by fix/check. Echoes output, returns the container exit code.
_run() {
  local tool="$1"
  if [[ -z "$_SVC" ]]; then
    log "routing error: '$tool' called before svc"
    return 125
  fi
  if (( DRY )); then
    printf '  would run: docker exec <%s> %s\n' "$_SVC" "$*" >&2
    return 0
  fi
  command -v docker >/dev/null 2>&1 || { log "docker not on PATH"; return 125; }
  exec_in "$_SVC" "$@"
}

fix() {
  _ROUTED=1
  (( DRY )) && { _run "$@" >/dev/null; return 0; }
  local out rc=0
  out="$(_run "$@")" || rc=$?
  (( rc != 0 )) && log "fix '$1' rc=$rc (non-blocking): ${out:0:200}"
  return 0
}

check() {
  _ROUTED=1
  [[ -n "$_VIOLATION" ]] && return 0   # fail-fast: one violation per edit is enough
  local out rc=0 tool="$1"
  out="$(_run "$@")" || rc=$?
  (( DRY )) && return 0

  case "$rc" in
    0) return 0 ;;
    124)
      log "budget exceeded (${VALIDATE_BUDGET_S}s): $tool on $REL"
      warn_once "budget-$_SVC-$tool" \
        "[validate] \`$tool\` exceeded the ${VALIDATE_BUDGET_S}s budget on $REL and was killed.
This tool is too slow for an on-edit hook — move it to the CI/verify stage and
remove it from the ROUTING TABLE, or raise VALIDATE_BUDGET_S deliberately." || true
      return 0 ;;
    125)
      log "no running container for service '$_SVC'"
      warn_once "nocontainer-$_SVC" \
        "[validate] service \`$_SVC\` has no running container, so $REL was not validated.
Start the stack (\`make up\`) to re-enable on-edit validation." || true
      return 0 ;;
    126|127)
      log "tool '$tool' not found in service '$_SVC'"
      warn_once "wiring-$_SVC-$tool" \
        "[validate] \`$tool\` is not installed in the \`$_SVC\` container, so $REL was not
validated. Add it to that service's dependencies, or drop it from the ROUTING
TABLE in .agents/hooks/validate-on-edit.sh." || true
      return 0 ;;
    *)
      [[ -z "${out//[$'\t\n\r ']/}" ]] && { log "$tool rc=$rc with no output, ignoring"; return 0; }
      _VIOLATION="[validate] $REL — $tool (exit $rc)

$out"
      return 0 ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# BEGIN ROUTING TABLE — project-specific. Everything above this line is generic.
#
# Ordering is first-match-wins:
#   1. explicit `skip` globs (generated files, fixtures, snapshots)
#   2. workspace branches (must precede generic extension branches)
#   3. generic extension branches
#   4. `*)` catch-all — leave it empty so unknown types warn once, or `skip`
#
# Rule of thumb: every branch must stay under ~1s. File-local linters only
# (eslint, biome, ruff, gofmt, php-cs-fixer). Project-wide type checkers
# (tsc --noEmit, phpstan, mypy --strict) belong in CI, never here.
# ═════════════════════════════════════════════════════════════════════════════
route() {
  case "$REL" in
    # 1. Explicitly not validated
    *.generated.*|*.snap|*.min.js|*.lock) skip ;;

    # 2. Workspace branches — replace with this project's real layout
    # apps/api/*)
    #   svc api; strip apps/api/
    #   check ruff check --fix "$F"
    #   ;;
    # apps/web/*)
    #   svc web; strip apps/web/
    #   check npx --no-install eslint --fix --max-warnings=0 "$F"
    #   ;;

    # 3. Generic extension branches
    # *.py) svc api; check ruff check --fix "$F" ;;

    # 4. Catch-all — no branch: the runner warns once per unknown extension.
    *) ;;
  esac
}
# ══════════════════════════════ END ROUTING TABLE ════════════════════════════

# ── Project root ─────────────────────────────────────────────────────────────
find_project_root() {
  local dir="$1" root=""
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$root" ]] && { printf '%s' "$root"; return; }
  while [[ "$dir" != "/" ]]; do
    for m in compose.yml compose.yaml docker-compose.yml docker-compose.yaml Makefile; do
      [[ -f "$dir/$m" ]] && { printf '%s' "$dir"; return; }
    done
    dir="$(dirname "$dir")"
  done
  printf ''
}

in_linked_worktree() {
  local gd gcd
  gd="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  gcd="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$gd" != "$gcd" ]]
}

# Should validation run inside this linked worktree?
#
# The container lookup is already worktree-aware: the compose project name is
# derived from the worktree's own directory, so a stack duplicated from the
# worktree resolves to ITS containers, and no stack at all resolves to nothing
# (125 -> warn once -> silence). Neither case can produce a false pass.
#
# The one case that can is COMPOSE_PROJECT_NAME exported in the environment:
# it pins every worktree to the SAME stack as the main checkout, whose bind
# mount holds a stale copy of the edited file. `auto` skips exactly that.
worktree_decision() {
  case "$VALIDATE_WORKTREE" in
    run)  printf 'run' ;;
    skip) printf 'skip' ;;
    *)    [[ -n "${COMPOSE_PROJECT_NAME:-}" ]] && printf 'skip' || printf 'run' ;;
  esac
}

is_excluded_path() {
  local rel="$1" d
  for d in $EXCLUDED_DIRS; do
    case "$rel" in "$d"*|*"/$d"*) return 0 ;; esac
  done
  return 1
}

# ── Retry brake — stop looping on a file the agent cannot fix ────────────────
# Every helper takes the repo-relative path explicitly: `muted` runs before
# validate_path has set $REL, so relying on that global silently hashes "".
retry_file() { printf '%s/retry-%s' "$STATE_DIR" "$(state_key "$1")"; }

retry_count() {
  local f; f="$(retry_file "$1")"
  [[ -f "$f" ]] && cat "$f" 2>/dev/null || printf '0'
}

retry_bump() {
  local f n; f="$(retry_file "$1")"
  n=$(( $(retry_count "$1") + 1 ))
  printf '%s' "$n" >"$f"
  printf '%s' "$n"
}

retry_reset() { rm -f "$(retry_file "$1")" 2>/dev/null || true; }

muted() {
  local f age; f="$(retry_file "$1")"
  [[ -f "$f" ]] || return 1
  (( $(cat "$f" 2>/dev/null || printf 0) >= VALIDATE_MAX_RETRIES )) || return 1
  age="$(file_age_s "$f")" || return 0
  (( age > VALIDATE_MUTE_TTL_S )) && { retry_reset "$1"; return 1; }
  return 0
}

# ── Validate one repo-relative path; sets _VIOLATION / WARNING ───────────────
validate_path() {
  REL="$1"; F="$REL"; _SVC=""; _SKIP=0; _ROUTED=0; _VIOLATION=""
  _DEADLINE=$(( $(date +%s) + VALIDATE_BUDGET_S ))

  is_excluded_path "$REL" && { log "excluded: $REL"; return 0; }

  route

  if (( _SKIP )); then log "skipped by routing: $REL"; return 0; fi

  if (( ! _ROUTED )); then
    local base ext
    base="${REL##*/}"; ext="${base##*.}"
    [[ "$ext" == "$base" ]] && ext="(no extension)" || ext=".$ext"
    log "no routing branch for $REL"
    warn_once "unrouted-$ext" \
      "[validate] no validation branch matches \`$ext\` files, so $REL was not checked.
Add a branch to the ROUTING TABLE in .agents/hooks/validate-on-edit.sh, or
declare the pattern under the \`skip\` arm if it is intentionally unchecked." || true
  fi
  return 0
}

# ── CLI modes ────────────────────────────────────────────────────────────────
cli_mode() {
  local mode="$1" arg="${2:-}"
  PROJECT_ROOT="$(find_project_root "$(pwd)")"
  [[ -z "$PROJECT_ROOT" ]] && { printf 'validate: no project root found\n' >&2; exit 1; }
  state_init
  HOST="cli"

  case "$mode" in
    --dry-run)
      [[ -z "$arg" ]] && { printf 'usage: %s --dry-run <path>\n' "$0" >&2; exit 64; }
      DRY=1
      printf 'project : %s\ncompose : %s\nfile    : %s\n' "$PROJECT_ROOT" "$(compose_project)" "$arg" >&2
      validate_path "$arg"
      printf 'service : %s\nin-ctr  : %s\nrouted  : %s  skipped: %s\n' \
        "${_SVC:-<none>}" "${F:-<none>}" "$_ROUTED" "$_SKIP" >&2
      ;;
    --check)
      [[ -z "$arg" ]] && { printf 'usage: %s --check <path>\n' "$0" >&2; exit 64; }
      local t0 t1
      t0="$(date +%s)"
      validate_path "$arg"
      t1="$(date +%s)"
      printf 'elapsed : %ss (budget %ss)\n' "$(( t1 - t0 ))" "$VALIDATE_BUDGET_S" >&2
      [[ -n "$_VIOLATION" ]] && { printf '%s\n' "$_VIOLATION" >&2; exit 1; }
      [[ -n "$WARNING" ]] && { printf '%s\n' "$WARNING" >&2; exit 0; }
      printf 'result  : clean\n' >&2
      ;;
    --doctor)
      printf 'project   : %s\n' "$PROJECT_ROOT"
      printf 'compose   : %s\n' "$(compose_project)"
      if in_linked_worktree; then
        printf 'worktree  : linked — %s (VALIDATE_WORKTREE=%s)\n' "$(worktree_decision)" "$VALIDATE_WORKTREE"
        [[ "$(worktree_decision)" == "skip" ]] && \
          printf '            COMPOSE_PROJECT_NAME=%s pins this worktree to the main stack.\n' "${COMPOSE_PROJECT_NAME:-}"
      else
        printf 'worktree  : main checkout\n'
      fi
      printf 'timeout   : %s\n' "${TIMEOUT_BIN:-bash watchdog fallback}"
      printf 'docker    : %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf 'UNREACHABLE')"
      printf 'services referenced by the routing table:\n'
      local s cid
      for s in $(grep -oE '(^|;)[[:space:]]*svc[[:space:]]+[a-zA-Z0-9_.-]+' "$0" | awk '{print $NF}' | sort -u); do
        cid="$(lookup_cid "$s")"
        printf '  %-20s %s\n' "$s" "${cid:-NOT RUNNING — run: make up}"
      done
      printf 'suppressed warnings this session: %s\n' "$(ls "$STATE_DIR"/warn-* 2>/dev/null | wc -l | tr -d ' ')"
      printf 'log       : %s\n' "$LOG_FILE"
      ;;
    *) printf 'unknown mode: %s\n' "$mode" >&2; exit 64 ;;
  esac
  exit 0
}

[[ "${1:-}" == --* ]] && cli_mode "$@"

# ── Hook mode ────────────────────────────────────────────────────────────────
[[ "$VALIDATE_ON_EDIT" == "0" ]] && exit 0

if [[ -t 0 ]]; then
  printf 'This is an agent hook. Usage: %s [--dry-run <path>|--check <path>|--doctor]\n' "$0" >&2
  exit 64
fi

PAYLOAD="$(cat)"
[[ -z "${PAYLOAD//[$'\t\n\r ']/}" ]] && exit 0

HOST="$(detect_host "$PAYLOAD")"
FILE_PATH="$(resolve_file_path "$PAYLOAD")"
[[ -z "$FILE_PATH" ]] && silent "no file path in payload"

if [[ "$FILE_PATH" == /* ]]; then
  PROJECT_ROOT="$(find_project_root "$(dirname "$FILE_PATH")")"
else
  PROJECT_ROOT="$(find_project_root "$(pwd)")"
fi
[[ -z "$PROJECT_ROOT" ]] && silent "no project root above $FILE_PATH"

state_init

if in_linked_worktree && [[ "$(worktree_decision)" == "skip" ]]; then
  silent "linked worktree pinned to the main stack by COMPOSE_PROJECT_NAME (VALIDATE_WORKTREE=$VALIDATE_WORKTREE)"
fi

if [[ "$FILE_PATH" == /* ]]; then
  case "$FILE_PATH" in
    "$PROJECT_ROOT/"*) REL_PATH="${FILE_PATH#"$PROJECT_ROOT/"}" ;;
    *) silent "file outside project root: $FILE_PATH" ;;
  esac
else
  REL_PATH="$FILE_PATH"
fi

[[ -f "$PROJECT_ROOT/$REL_PATH" ]] || silent "file gone: $REL_PATH"

muted "$REL_PATH" && silent "muted after $VALIDATE_MAX_RETRIES rejections: $REL_PATH"

cd "$PROJECT_ROOT" 2>/dev/null || silent "cannot cd to $PROJECT_ROOT"

validate_path "$REL_PATH"

if [[ -n "$_VIOLATION" ]]; then
  n="$(retry_bump "$REL_PATH")"
  if (( n >= VALIDATE_MAX_RETRIES )); then
    emit_feedback "$_VIOLATION

[validate] $n consecutive rejections on this file — validation is now muted for
it (${VALIDATE_MUTE_TTL_S}s). Fix it, adjust the linter config, or say why it must stay
as is; nothing further will be reported for this path."
  fi
  emit_feedback "$_VIOLATION"
fi

retry_reset "$REL_PATH"
[[ -n "$WARNING" ]] && emit_feedback "$WARNING"
exit 0
