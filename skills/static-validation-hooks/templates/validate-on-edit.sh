#!/usr/bin/env bash
# .agents/hooks/validate-on-edit.sh
#
# Static-validation hook. Runs after every agent file edit, routes the touched
# file to a fast file-local linter inside an ALREADY-RUNNING compose container,
# and stays silent unless something is wrong.
#
# Two layers live in this file:
#   1. The RUNNER (everything OUTSIDE the ROUTING TABLE markers, above AND
#      below them) — generic, copy as-is. Owns the agent protocol, container
#      resolution, time budget, retry brake, the CLI modes and the hook entry.
#   2. The ROUTING TABLE (between the BEGIN/END markers) — project-specific.
#      This is the only part you edit. See skills/static-validation-hooks.
#
# Agent protocol:
#   Claude  violations -> stderr + exit 2  (Claude feeds stderr back to the model)
#   Cursor  violations -> stdout {"additional_context": ...} + exit 0 (postToolUse)
#   Silent  everything else -> exit 0, no output
#
# Env knobs (all optional):
#   VALIDATE_ON_EDIT=0      Kill-switch. Default 1.
#   VALIDATE_BUDGET_S=3     Hard wall-clock cap per command. Default 3.
#   VALIDATE_MAX_RETRIES=3  Consecutive rejections on one file before muting it.
#   VALIDATE_MUTE_TTL_S=900 How long a muted file stays muted. Default 900.
#   VALIDATE_WARN_TTL_S=900 How long a once-per-session warning stays suppressed
#                           when the host sends no session id. Default 900.
#   VALIDATE_WORKTREE=auto  auto|skip|run — behaviour inside a linked worktree.
#   VALIDATE_HOST           claude|cursor — force the response shape (else sniffed).
#   VALIDATE_DEBUG=1        Verbose trace to stderr and the log file.
#
# CLI (for humans, not the agent):
#   validate-on-edit.sh --dry-run <path>   Show routing decision, run nothing.
#   validate-on-edit.sh --check <path>     Run the real validation, print timing.
#   validate-on-edit.sh --doctor           Docker, the resolved Compose project
#                                          and where its name came from, the
#                                          Compose files, whether this project root
#                                          has two spellings, each routed service,
#                                          whether it is classified in the degraded
#                                          (shell-less) mode, and whether its
#                                          container can see the file routed to it.

# No 'set -e': (( )) returns 1 on a zero result, which is not an error here.
set -uo pipefail

VALIDATE_ON_EDIT="${VALIDATE_ON_EDIT:-1}"
VALIDATE_BUDGET_S="${VALIDATE_BUDGET_S:-3}"
VALIDATE_MAX_RETRIES="${VALIDATE_MAX_RETRIES:-3}"
VALIDATE_MUTE_TTL_S="${VALIDATE_MUTE_TTL_S:-900}"
VALIDATE_WARN_TTL_S="${VALIDATE_WARN_TTL_S:-900}"
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
  # Both hosts send `tool_input`, `session_id` and `hook_event_name` on their
  # post-edit event, so none of those can tell them apart. Cursor's postToolUse
  # carries `cursor_version` and `tool_output`; Claude's PostToolUse carries
  # `tool_response`. A key sniffed as `"name"` cannot match text nested inside a
  # JSON string, where the quotes arrive escaped as \"name\".
  case "$1" in
    *'"cursor_version"'*) printf 'cursor' ;;
    *'"tool_response"'*)  printf 'claude' ;;
    *'"tool_output"'*)    printf 'cursor' ;;
    *'"tool_input"'*)     printf 'claude' ;;
    *)                    printf 'cursor' ;;
  esac
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Claude reads stderr on exit 2. Cursor (postToolUse) reads `additional_context`
# from a JSON object on stdout, exit 0: the edit already happened, so there is
# nothing to block, and exit 2 would be read as a deny of a done action.
emit_feedback() {
  local msg="$1"
  if [[ "$HOST" == "claude" ]]; then
    printf '%s\n' "$msg" >&2
    exit 2
  fi
  printf '{"additional_context":"%s"}\n' "$(json_escape "$msg")"
  exit 0
}

# ── State (bash 3.2 compatible: files, not associative arrays) ────────────────
#
# The host's session id, when the payload carries one. Claude sends `session_id`
# on every PostToolUse event; a host that sends none leaves this empty and the
# warning sentinels fall back to their time to live (see warn_once).
_SESSION_ID=""

state_key() { printf '%s' "$1" | cksum | tr -d ' \n'; }

state_init() {
  STATE_DIR="${TMPDIR:-/tmp}/validate-on-edit/$(state_key "$PROJECT_ROOT")"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

# Warn the agent about a given condition at most once per session.
#
# "Per session" is not the same thing as "per project root", and keying it on
# the root alone — as this did — means once for the lifetime of $TMPDIR. A
# daemon outage on Monday then suppresses a genuine one on Wednesday, after
# Docker recovered and broke again: WARNING stays empty and the hook exits in
# silence, which the agent cannot tell from a clean file.
#
# Two scopes, both needed, because neither covers the other:
#   1. the host's own session id, when it sends one ($_SESSION_ID, taken from
#      the hook payload). Two sessions running side by side then hold separate
#      sentinels, which is what "once per session" says.
#   2. a time to live, for hosts that send no session id — the same mechanism
#      the retry brake already uses (`muted`). An expired sentinel is replaced,
#      not re-read, so the next outage warns again.
#
# NOTE: `id` must be assigned before it is used — a single `local a=1 b="$a"`
# expands every word before the assignments happen, so $a would be unbound.
warn_once() {
  local id="$1" msg="$2" age=""
  local sentinel="$STATE_DIR/warn-$(state_key "${_SESSION_ID}|$id")"
  if [[ -f "$sentinel" ]]; then
    age="$(file_age_s "$sentinel")" || age=0
    if (( age <= VALIDATE_WARN_TTL_S )); then log "warn suppressed: $id"; return 1; fi
    log "warn sentinel expired after ${age}s: $id"
  fi
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

# A budget kill is recognised by THIS file's own sentinel, never by exit 124:
# a validator may legitimately choose 124 as its own signal, and claiming that
# code for the runner is the same mistake as claiming 125 for a missing
# container. with_budget runs inside a command substitution, so the sentinel is
# a file the caller can read afterwards, not a variable.
#
# On the branch that delegates to an external `timeout`, the utility's own 124
# and a validator's own 124 carry the same status — timeout reports nothing of
# its own — so the STATUS cannot separate them and a second piece of evidence is
# needed. It is the elapsed time, and it was measured rather than assumed
# (2026-09-17, GNU coreutils 9.11 `timeout`, Docker 29.4.0 via OrbStack):
#
#   timeout 3 sleep 30                          rc 124, elapsed 3.009 s
#   timeout 1 sleep 30                          rc 124, elapsed 1.009 s
#   timeout 3 sh -c 'exit 124'                  rc 124, elapsed 0.014 s
#   timeout 3 docker exec … 'printf …; exit 124' rc 124, elapsed 0.058 s
#   timeout 3 docker exec … 'sleep 30'          rc 124, elapsed 3.011 s
#   timeout 2 docker exec … 'sleep 1.8; exit 124' rc 124, elapsed 1.850 s
#
# A child killed at the boundary returns AT the boundary — every measured kill
# overshot the limit by 9 to 11 ms and none undershot it. A child that chose 124
# returns whenever it finished. So the budget flag is raised only when the
# elapsed time reached the limit, and a validator that printed a finding and
# exited 124 keeps that finding instead of being reported as "was killed".
#
# `date +%s` is NOT the instrument: it is second-resolution, and the 0.058 s run
# above straddled a second boundary and measured as 1. The bash `time` keyword
# with TIMEFORMAT='%3R' gives milliseconds, is a bash 3.2 builtin, and needs no
# external clock. Its decimal separator follows the locale, so the value is read
# by keeping the digits and dropping everything else — '3.009' and '3,009' both
# become 3009 ms, because %3R always prints exactly three decimals.
#
# HONEST LIMIT, narrowed but not closed: a validator that chooses 124 within the
# last few milliseconds of the budget is still read as a kill. The remaining
# window is the measurement's own overshoot, not the whole budget.
_BUDGET_FLAG=""

# The sentinel carries WHICH of the two budget outcomes happened, because the
# agent-visible sentence differs and only one of them is a kill:
#   killed   the command started and the runner (or `timeout`) stopped it
#   unspent  the budget was already gone before the command started, so nothing
#            was invoked at all — telling the agent its tool "was killed" there
#            would assert a cause the runner never established (FR-022)
budget_flag_arm() {
  _BUDGET_FLAG="$STATE_DIR/budget-killed-$$"
  rm -f "$_BUDGET_FLAG" 2>/dev/null || true
}

budget_flag_raise() { [[ -n "$_BUDGET_FLAG" ]] && printf '%s' "${1:-killed}" >"$_BUDGET_FLAG"; return 0; }

budget_was_killed() { [[ -n "$_BUDGET_FLAG" && -f "$_BUDGET_FLAG" ]]; }

budget_reason() { [[ -n "$_BUDGET_FLAG" ]] && cat "$_BUDGET_FLAG" 2>/dev/null; return 0; }

# Output goes to a file, never to a command substitution: killing the direct
# child does not close a pipe its own descendants still hold open, so `$( )`
# would block for the full runtime of a grandchild and the budget would be a
# lie. Returns the command's exit code, or 124 when the budget ran out.
#
# No time left means NOTHING is invoked and NO temporary file is created: an
# external `timeout` reads 0 as "no limit", which would turn an exhausted budget
# into an unbounded call, and the file the old order created on that path was
# never unlinked — one stray per edit (FR-023).
with_budget() {
  local left; left="$(remaining_budget)"
  BUDGET_OUT=""
  (( left <= 0 )) && { budget_flag_raise unspent; return 124; }
  BUDGET_OUT="$(mktemp "${TMPDIR:-/tmp}/validate-out-XXXXXX")" || {
    BUDGET_OUT=""; log "cannot create the budget output file"; return 125
  }

  if [[ -n "$TIMEOUT_BIN" ]]; then
    # The timing file is this call's own and is unlinked before returning on
    # every branch, so it cannot survive the edit (FR-023).
    local tf="${BUDGET_OUT}.elapsed" trc=0 ms=""
    local TIMEFORMAT='%3R'
    { time "$TIMEOUT_BIN" "$left" "$@" >"$BUDGET_OUT" 2>&1 ; } 2>"$tf"
    trc=$?
    ms="$(tr -cd '0-9' <"$tf" 2>/dev/null)"
    rm -f "$tf" 2>/dev/null || true
    if (( trc == 124 )); then
      # No reading at all: fall back to the safe side, which is what this branch
      # did unconditionally before.
      if [[ -z "$ms" ]]; then
        log "the elapsed time could not be read — treating exit 124 as a kill"
        budget_flag_raise
      # `10#` is not decoration: %3R pads to three decimals, so a run under
      # 100 ms reads as `0048`, and bash takes a leading zero for octal — `((
      # 0048 ))` is a fatal "value too great for base" on the busiest arm of
      # this file. Caught by the suite on debian, on one run in eight.
      elif (( 10#$ms >= left * 1000 )); then
        log "exit 124 after ${ms}ms of a ${left}s limit — the runner's timeout killed it"
        budget_flag_raise
      else
        log "exit 124 after ${ms}ms of a ${left}s limit — the validator's own code, not a kill"
      fi
    fi
    return "$trc"
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
  [[ -f "$sentinel" ]] && { rm -f "$sentinel"; budget_flag_raise; return 124; }
  return "$rc"
}

# bounded CMD... — run a RESOLUTION command under the edit's remaining budget,
# pass its stdout on, and return its status, or 124 when the budget ran out.
#
# The budget is advertised as a wall-clock cap on the whole edit, and until this
# existed it covered only the validator: `docker compose config`, `docker
# compose ls`, `docker ps`, `docker inspect` and the shell probe all ran
# unbounded, so a Docker endpoint that accepted the connection and then stalled
# made a 3-second hook wait for the client's own timeout — minutes, on a TCP
# endpoint — before deciding anything.
#
# Deliberately NOT with_budget: that one owns $BUDGET_OUT and the kill sentinel
# that classify a VALIDATOR run, and a resolution probe borrowing them would
# overwrite the evidence the current edit is being judged on. Output goes to a
# file for the same reason with_budget does — killing a direct child does not
# close a pipe its descendants still hold — and that file is unlinked before
# returning on every branch (FR-023).
#
# With no deadline armed (the --doctor and --dry-run paths, which are human CLI
# modes and not an edit) the command runs unbounded, as it always did.
bounded() {
  local left out rc=0 pid timer sentinel
  if (( _DEADLINE == 0 )); then "$@"; return $?; fi
  left="$(remaining_budget)"
  (( left <= 0 )) && return 124
  out="$(mktemp "${TMPDIR:-/tmp}/validate-probe-XXXXXX")" || return 125

  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$left" "$@" >"$out" 2>/dev/null
    rc=$?
  else
    "$@" >"$out" 2>/dev/null </dev/null &
    pid=$!
    sentinel="$out.killed"
    ( sleep "$left"; kill -9 "$pid" 2>/dev/null && : >"$sentinel" ) >/dev/null 2>&1 </dev/null &
    timer=$!
    wait "$pid" 2>/dev/null || rc=$?
    kill "$timer" 2>/dev/null || true
    wait "$timer" 2>/dev/null || true
    [[ -f "$sentinel" ]] && { rm -f "$sentinel"; rc=124; }
  fi

  cat "$out"
  rm -f "$out" 2>/dev/null || true
  return "$rc"
}

# ── Container resolution (cached; the hot path is a single `docker exec`) ─────
#
# ── The Compose project name (plan D5, FR-011, FR-012, FR-018, FR-019) ───────
#
# Resolved at RESOLUTION TIME only and remembered in a file, because the runner
# is a fresh process per edit. Three sources, highest first:
#
#   1. a consumer override of this resolver placed inside the ROUTING TABLE
#      markers. It replaces the whole function body, marker included, so it
#      wins outright — and it also waives the checkout-identity test below,
#      because the consumer has taken over the question (FR-019).
#   2. Compose itself: `docker compose config --format json`, TOP-LEVEL `name`.
#   3. today's rule — COMPOSE_PROJECT_NAME exported, else the sanitised
#      directory basename — when there is no Compose file, or Compose fails.
#      FR-011 asks for exactly this fallback, and for the runner to say which
#      rule it used; `--doctor` prints it.
#
# The exported variable is read BEFORE asking Compose, and only as an
# optimisation: it is Compose's own highest-precedence source, so Compose would
# return the same value 64 ms later. Every other source is Compose's business.
#
# Compose is ASKED rather than imitated, so the project `.env`, the `name:` key
# and an override file are honoured without this runner tracking Compose's
# precedence. Measured 2026-09-17, Compose v5.1.2 on Docker 29.4.0 via OrbStack:
# `config --format json` 64 ms, `ls --format json` 74 ms — against a basename
# that is wrong for the repository where the defect was first seen (`compose.yml`
# declares `name: broker-pa`, the directory is `modelo-broker-pa`).
#
# WHAT THIS CANNOT SEE, stated rather than claimed away: a file list (`-f`) or a
# project name (`-p`) passed on the command line when the stack was started. The
# hook runs in a different environment from that `up`, so both are invisible to
# it, and no measurement here changes that.
_COMPOSE_NAME=""
_COMPOSE_SOURCE=""
_COMPOSE_FILES=""

# Compose normalises a project name before it becomes a container label:
# lowercased and reduced to [a-z0-9_-]. Measured 2026-09-17: `name:
# VOE.Test.Upper` is reported by Compose as `voetestupper` — dots dropped, not
# replaced. Applied to every source so a hand-written value matches too (FR-012).
compose_name_normalise() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# The TOP-LEVEL "name" of a JSON document on stdin.
#
# NOT `extract_json_string`: that helper returns the FIRST `"name"` in the
# document (:58-80). `docker compose config --format json` serialises its
# top-level keys in alphabetical order, so a project whose services use a
# `configs:` entry puts that entry's own `name` BEFORE the project's own —
# measured 2026-09-17, Compose v5.1.2. Reusing the helper here would resolve a
# config's name as the project, which is the same shape of defect this feature
# exists to remove: a helper that is right on the documents it was written
# against and silently wrong on the next one.
#
# Depth is tracked through strings and escapes, and only a key sitting at depth 1
# can match. An escape inside the value is passed through verbatim; a project
# name survives compose_name_normalise regardless.
json_top_level_name() {
  awk '
    {
      line = $0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (instr) {
          if (esc) { esc = 0; buf = buf c; continue }
          if (c == "\\") { esc = 1; buf = buf c; continue }
          if (c == "\"") {
            instr = 0
            if (expectval) {
              expectval = 0
              if (depth == 1 && key == "name") { printf "%s", buf; exit }
            } else { key = buf }
            continue
          }
          buf = buf c
          continue
        }
        if (c == "\"") { instr = 1; buf = ""; continue }
        if (c == "{" || c == "[") { depth++; expectval = 0; continue }
        if (c == "}" || c == "]") { depth--; expectval = 0; continue }
        if (c == ":") { expectval = 1; continue }
        if (c == ",") { expectval = 0; key = ""; continue }
      }
    }
  '
}

# The Compose files present in the project root, absolute, one per line. Used to
# decide whether Compose is worth asking at all, and as one half of the cache
# fingerprint — an override file that appears must invalidate the name.
compose_files_present() {
  local root="${PROJECT_ROOT:-}" f
  [[ -n "$root" ]] || return 0
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml \
           compose.override.yaml compose.override.yml \
           docker-compose.override.yaml docker-compose.override.yml; do
    [[ -f "$root/$f" ]] && printf '%s/%s\n' "${root%/}" "$f"
  done
  return 0
}

# The files COMPOSE ITSELF reports for this project (FR-011: recorded, not
# inferred). Only a project with containers appears in `docker compose ls`, so
# an answer here is a bonus over compose_files_present, never a replacement.
compose_reported_files() {
  bounded docker compose ls --format json 2>/dev/null \
    | tr '{' '\n' \
    | grep -F "\"Name\":\"$1\"" \
    | sed -n 's/.*"ConfigFiles":"\([^"]*\)".*/\1/p' \
    | head -n1 \
    | tr ',' '\n'
  return 0
}

compose_union() { printf '%s\n%s\n' "$1" "$2" | grep -v '^[[:space:]]*$' | sort -u; return 0; }

# The Compose files named by COMPOSE_FILE, absolute, one per line. Compose reads
# that variable as a LIST separated by COMPOSE_PATH_SEPARATOR (':' unless the
# consumer says otherwise), and a relative entry is resolved against the project
# root, which is where compose_resolve runs Compose from.
compose_declared_files() {
  local root="${PROJECT_ROOT:-}" sep="${COMPOSE_PATH_SEPARATOR:-:}" f
  [[ -n "${COMPOSE_FILE:-}" ]] || return 0
  # `printf '%s\n'`, not '%s': `read` returns non-zero on a last line with no
  # newline, so the loop would drop the only entry of a single-file list.
  printf '%s\n' "$COMPOSE_FILE" | tr "$sep" '\n' | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      /*) printf '%s\n' "$f" ;;
      *)  printf '%s/%s\n' "${root%/}" "$f" ;;
    esac
  done
  return 0
}

# The env files Compose will read for variable interpolation: COMPOSE_ENV_FILES
# when the consumer set it (a comma-separated list, per Compose), otherwise the
# project `.env`.
compose_env_files() {
  local root="${PROJECT_ROOT:-}" f
  if [[ -n "${COMPOSE_ENV_FILES:-}" ]]; then
    printf '%s\n' "$COMPOSE_ENV_FILES" | tr ',' '\n' | while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in
        /*) printf '%s\n' "$f" ;;
        *)  printf '%s/%s\n' "${root%/}" "$f" ;;
      esac
    done
    return 0
  fi
  [[ -n "$root" ]] && printf '%s/.env\n' "${root%/}"
  return 0
}

# The fingerprint the name cache is keyed on (plan D5): the Compose files and
# env files by CONTENT, the values of every variable they interpolate, and the
# Compose-related environment.
#
# Two inputs were missing, and each one silently pins a stale project name:
#
#   interpolation. A Compose file whose project is `name: ${STACK_NAME}` changes
#   project when the variable changes, with no file touched at all. So the
#   variable NAMES referenced by those files are read out of them, and their
#   values join the fingerprint. Values come from the environment, which is the
#   only place this process can read them; a value living in an env file is
#   covered by that file's own content hash instead.
#
#   content, not timestamps. COMPOSE_ENV_FILES was recorded by PATH, so a
#   rewritten env file changed nothing; and mtimes are second-resolution, so a
#   same-second rewrite — or one that preserves the timestamp, which `cp -p` and
#   every restore-from-archive does — was invisible. `cksum` reads the bytes.
compose_fingerprint() {
  local files="$1" f h out all v
  out="env|${COMPOSE_PROJECT_NAME:-}|${COMPOSE_FILE:-}|${COMPOSE_PATH_SEPARATOR:-}"
  out="$out|${COMPOSE_PROFILES:-}|${COMPOSE_ENV_FILES:-}|${DOCKER_HOST:-}|${DOCKER_CONTEXT:-}"
  all="$(compose_union "$files" "$(compose_env_files)")"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    h=""
    [[ -r "$f" ]] && h="$(cksum <"$f" | tr -d ' \n')"
    out="$out|$f#${h:-absent}"
  done <<EOF
$all
EOF
  # `$VAR` and `${VAR…}` alike; a name is validated by the pattern that matched
  # it, and the value is read with printenv rather than through eval.
  for v in $(printf '%s\n' "$all" | while IFS= read -r f; do
               [[ -n "$f" && -f "$f" ]] && grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null
             done | sed 's/^\${*//' | sort -u); do
    out="$out|$v=$(printenv "$v" 2>/dev/null)"
  done
  printf '%s' "$out" | cksum | tr -d ' \n'
}

compose_cache_file() { [[ -n "${STATE_DIR:-}" ]] && printf '%s/compose-name' "$STATE_DIR"; return 0; }

compose_resolve() {
  [[ -n "$_COMPOSE_NAME" ]] && return 0
  local root="${PROJECT_ROOT:-}"

  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    _COMPOSE_NAME="$(compose_name_normalise "$COMPOSE_PROJECT_NAME")"
    _COMPOSE_SOURCE="COMPOSE_PROJECT_NAME exported in the environment"
    return 0
  fi

  # A Compose file the consumer named explicitly counts as much as one sitting
  # in the project root — more, since COMPOSE_FILE overrides the root file for
  # Compose itself. Asking only about root files returned the basename before
  # Compose was ever consulted, so `COMPOSE_FILE=deploy/compose.yml` in a
  # repository with no root Compose file resolved a project no container carries.
  local present declared
  present="$(compose_files_present)"
  declared="$(compose_declared_files)"
  present="$(compose_union "$present" "$declared")"
  if [[ -z "$present" ]]; then
    _COMPOSE_NAME="$(compose_name_normalise "$(basename "$root")")"
    _COMPOSE_SOURCE="the directory basename (no Compose file in the project root)"
    return 0
  fi

  local cache; cache="$(compose_cache_file)"
  if [[ -n "$cache" && -f "$cache" ]]; then
    local sfp sname ssrc sfiles fp
    sfp="$(sed -n '1p' "$cache" 2>/dev/null)"
    sname="$(sed -n '2p' "$cache" 2>/dev/null)"
    ssrc="$(sed -n '3p' "$cache" 2>/dev/null)"
    sfiles="$(sed -n '4,$p' "$cache" 2>/dev/null)"
    fp="$(compose_fingerprint "$(compose_union "$sfiles" "$present")")"
    if [[ -n "$sname" && "$fp" == "$sfp" ]]; then
      _COMPOSE_NAME="$sname"; _COMPOSE_SOURCE="$ssrc"; _COMPOSE_FILES="$sfiles"
      return 0
    fi
    log "the Compose fingerprint changed — resolving the project name again"
  fi

  local json="" name=""
  json="$(cd "$root" 2>/dev/null && bounded docker compose config --format json 2>/dev/null)"
  [[ -n "$json" ]] && name="$(printf '%s' "$json" | json_top_level_name)"
  name="$(compose_name_normalise "$name")"

  if [[ -z "$name" ]]; then
    _COMPOSE_NAME="$(compose_name_normalise "$(basename "$root")")"
    _COMPOSE_SOURCE="the directory basename (Compose did not answer)"
    _COMPOSE_FILES="$present"
    return 0
  fi

  _COMPOSE_NAME="$name"
  _COMPOSE_SOURCE="Compose itself (docker compose config, top-level name)"
  _COMPOSE_FILES="$(compose_union "$(compose_reported_files "$name")" "$present")"
  log "compose project '$_COMPOSE_NAME' from $_COMPOSE_SOURCE"
  if [[ -n "$cache" ]]; then
    { printf '%s\n%s\n%s\n%s\n' "$(compose_fingerprint "$_COMPOSE_FILES")" \
        "$_COMPOSE_NAME" "$_COMPOSE_SOURCE" "$_COMPOSE_FILES"; } >"$cache" 2>/dev/null || true
  fi
  return 0
}

# A consumer redefines THIS function inside the ROUTING TABLE markers to take
# over resolution; bash keeps the last definition, so the override needs no
# support from the runner. The marker is how the runner notices it happened.
compose_project() {
  : "__voe_factory_resolver__"
  compose_resolve
  printf '%s' "$_COMPOSE_NAME"
}

# Positive evidence only: a `declare -f` that answers nothing is read as the
# factory resolver, never as an override, so an unreadable definition cannot
# silently waive the checkout-identity test.
resolver_is_overridden() {
  local def
  def="$(declare -f compose_project 2>/dev/null)"
  [[ -n "$def" ]] || return 1
  case "$def" in *__voe_factory_resolver__*) return 1 ;; esac
  return 0
}

compose_source() { compose_resolve; printf '%s' "${_COMPOSE_SOURCE:-unknown}"; return 0; }
compose_files()  { compose_resolve; printf '%s' "${_COMPOSE_FILES:-}"; return 0; }

# lookup_candidates SERVICE — every running container id for the service, one
# per line, and DOCKER'S OWN exit status. The whole set is the evidence: which
# cause occurred is a question about the set, not about its first line (plan D3).
#
# `| head -n1` is gone from the query itself. Two reasons, and only the second
# was measured. It can in principle close the pipe on docker mid-write, which
# under `set -o pipefail` surfaces as a non-zero status indistinguishable from
# a dead daemon — probed on 2026-09-17 with 8 containers on one label pair, ten
# runs, rc 0 every time, so that hazard is theoretical at any plausible scale
# (8 short ids are ~100 bytes against a 64 KB pipe buffer). What is NOT
# theoretical is that the first line alone cannot answer whether the cached id
# is still among the candidates, which is the question separating "the container
# was replaced" from "it is alive and the call did not get inside it".
# Bounded like every other resolution call (FR-010): a Docker endpoint that
# accepts the connection and then stalls must not make a 3-second hook wait for
# the client's own timeout. A budget kill surfaces here as 124, which the caller
# reports as its own cause rather than folding into "the daemon is down".
lookup_candidates() {
  bounded docker ps -q \
    --filter "label=com.docker.compose.project=$(compose_project)" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null
}

# lookup_cid SERVICE — the first candidate, for the diagnostic and for callers
# that only need "is something running". It keeps whether docker SUCCEEDED, not
# docker's own code: a failed lookup is collapsed to 1. Nothing reads the value,
# and the cause decision in exec_in uses lookup_candidates directly, where the
# whole set and docker's own status are both preserved.
lookup_cid() {
  local out=""
  out="$(lookup_candidates "$1")" || return 1
  printf '%s' "${out%%$'\n'*}"
}

# cands_contain SET ID — is ID one of the candidates? `docker ps -q` prints
# 12-character ids while a cache written by another tool may hold the full 64,
# so the comparison is by prefix in both directions rather than by equality.
cands_contain() {
  local cands="$1" id="$2" c=""
  [[ -n "$id" ]] || return 1
  for c in $cands; do
    [[ "$c" == "$id" ]] && return 0
    case "$id" in "$c"*) return 0 ;; esac
    case "$c" in "$id"*) return 0 ;; esac
  done
  return 1
}

# ── Checkout identity (plan D6, FR-013 to FR-016) ────────────────────────────
#
# At RESOLUTION TIME only, never on the path that reuses a cached identifier, so
# the per-edit cost stays zero. One `docker inspect` — 25 ms measured — carries
# the working directory and every mount's type, source and destination.
#
# THE TEST STARTS FROM THE CONTAINER PATH, NOT FROM THE HOST PATH. A source-only
# test — "is some mount source a parent of the edited file" — is wrong in both
# directions, and that was measured rather than argued (research.md §3d): a
# checkout bound at /app with a named volume over /app/src makes the validator
# read the volume's stale copy, and a source-only test accepts that container.
#
#   1. the path the validator will be given ($F after `strip`, made absolute
#      with the container's working directory). The mount with the DEEPEST
#      destination that is a prefix of it is the one that serves it. A volume
#      there is refused outright: it is not this checkout, whatever its name.
#   2. when no mount serves that path — a relative $F whose real container path
#      the ROUTING TABLE composed itself — the mounts are walked the other way:
#      a bind whose source holds the edited file yields a candidate container
#      path, and that candidate is refused when a deeper mount shadows it. The
#      same refusal, reached from the other end, so the shadowing case is caught
#      on both routes rather than only on the derivable one.
#
# CANONICALISATION IS NOT OPTIONAL, and research.md §3's note that Docker
# "reports mount sources already resolved" does not hold on this platform:
# measured 2026-09-17, OrbStack reports a bind source as /var/folders/… while
# the physical path is /private/var/folders/… . Both sides go through
# `cd … && pwd -P` before any comparison.
_IDENTITY_REASON=""

path_canon() {
  local p="$1" d b
  [[ -n "$p" ]] || return 1
  if [[ -d "$p" ]]; then (cd "$p" 2>/dev/null && pwd -P); return; fi
  d="$(dirname "$p")"; b="$(basename "$p")"
  d="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$d" ]] || return 1
  printf '%s/%s' "${d%/}" "$b"
}

# Is $1 the path $2 itself, or below it? String comparison only — both sides are
# canonicalised by the caller.
path_within() {
  local p="$1" parent="$2"
  [[ -n "$p" && -n "$parent" ]] || return 1
  [[ "$p" == "$parent" ]] && return 0
  case "$p" in "${parent%/}/"*) return 0 ;; esac
  return 1
}

# Working directory on line 1, then one `type|source|destination` per mount.
container_facts() {
  bounded docker inspect \
    -f '{{.Config.WorkingDir}}{{range .Mounts}}{{"\n"}}{{.Type}}|{{.Source}}|{{.Destination}}{{end}}' \
    "$1" 2>/dev/null
}

# container_reads_checkout CID HOSTFILE PATH_GIVEN_TO_THE_VALIDATOR
#
# Three answers, not two, because "this container serves another checkout" and
# "the facts could not be read" are different facts about the world and only the
# first one was established by anything:
#   0  the container reads this checkout
#   1  it does not — a refusal the runner PROVED
#   2  undecided: the inspection itself failed, so nothing was proved either way
container_reads_checkout() {
  local cid="$1" hostfile="$2" given="$3"
  local facts mounts wd cpath="" line t s d canon_file canon_src
  local best_dest="" best_src="" best_type=""
  _IDENTITY_REASON=""

  facts="$(container_facts "$cid")"
  [[ -n "$facts" ]] || { _IDENTITY_REASON="the container could not be inspected"; return 2; }
  wd="$(printf '%s' "$facts" | sed -n '1p')"
  mounts="$(printf '%s' "$facts" | sed -n '2,$p')"

  canon_file="$(path_canon "$hostfile")" || canon_file="$hostfile"

  case "$given" in
    /*) cpath="$given" ;;
    *)  cpath="${wd:-/}"; cpath="${cpath%/}/$given" ;;
  esac

  # 1. the mount with the deepest destination that serves that path.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    t="${line%%|*}"; s="${line#*|}"; d="${s#*|}"; s="${s%%|*}"
    path_within "$cpath" "$d" || continue
    if [[ ${#d} -gt ${#best_dest} ]]; then best_dest="$d"; best_src="$s"; best_type="$t"; fi
  done <<EOF
$mounts
EOF

  if [[ -n "$best_dest" ]]; then
    if [[ "$best_type" != "bind" ]]; then
      _IDENTITY_REASON="$cpath is served by a $best_type mount at $best_dest, not by this checkout"
      return 1
    fi
    canon_src="$(path_canon "$best_src")" || canon_src="$best_src"
    if path_within "$canon_file" "$canon_src"; then
      _IDENTITY_REASON="$best_src -> $best_dest serves $cpath"
      return 0
    fi
    _IDENTITY_REASON="$cpath comes from $best_src, which does not hold $hostfile"
    return 1
  fi

  # 2. no mount serves the derived path: walk the mounts the other way.
  local m_type m_src m_dest cand shadowed line2 d2
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    m_type="${line%%|*}"; m_src="${line#*|}"; m_dest="${m_src#*|}"; m_src="${m_src%%|*}"
    [[ "$m_type" == "bind" ]] || continue
    canon_src="$(path_canon "$m_src")" || canon_src="$m_src"
    path_within "$canon_file" "$canon_src" || continue
    if [[ "$canon_file" == "$canon_src" ]]; then
      cand="$m_dest"
    else
      cand="${m_dest%/}/${canon_file#"${canon_src%/}/"}"
    fi
    shadowed=0
    while IFS= read -r line2; do
      [[ -z "$line2" ]] && continue
      d2="${line2#*|}"; d2="${d2#*|}"
      [[ "$d2" == "$m_dest" ]] && continue
      if path_within "$cand" "$d2" && [[ ${#d2} -gt ${#m_dest} ]]; then shadowed=1; fi
    done <<EOF2
$mounts
EOF2
    (( shadowed )) && continue
    _IDENTITY_REASON="$m_src -> $m_dest holds $hostfile as $cand"
    return 0
  done <<EOF
$mounts
EOF

  _IDENTITY_REASON="no bind mount in this container holds $hostfile"
  return 1
}

# identity_ok SERVICE CID — may this container be used for the current edit?
#
# Two escapes, both required to survive (FR-015, FR-019):
#   VALIDATE_WORKTREE=run   a consumer sharing one stack across checkouts
#   a ROUTING TABLE override of compose_project — the consumer has taken over
#     which stack is addressed, so the runner does not second-guess it
#
# A third, silent path: with no budget left the check is SKIPPED and the
# container accepted, because `docker inspect` is a call the edit can no longer
# afford. That is the permissive direction, and it is deliberate — refusing on
# an exhausted budget would turn a slow machine into a stream of checkout-
# mismatch warnings about containers that are in fact this checkout's.
#
# But an acceptance is not a proof, and the two must not be confused ONE FRAME
# UP, where the caller writes the container id into a cache that survives the
# edit: the current edit would take the permissive answer it paid nothing for,
# and every later edit would take the unchecked hot path on a container whose
# identity was never established. So identity_ok also reports whether it proved
# anything, in _IDENTITY_PROVED, and only a proof may be cached.
#
# The two waivers DO count as decided: a consumer that set VALIDATE_WORKTREE=run
# or took over compose_project has answered the question itself (FR-015, FR-019),
# which is a decision, not a skipped check.
#
#   return 0 + _IDENTITY_PROVED=1   accepted, and established
#   return 0 + _IDENTITY_PROVED=0   accepted for this edit only, nothing proved
#   return 1                        refused, and the refusal was established
#   return 2                        undecided — the facts could not be read
_IDENTITY_PROVED=0

identity_ok() {
  local svc="$1" cid="$2" hostfile="" rc=0
  _IDENTITY_PROVED=0
  [[ "$VALIDATE_WORKTREE" == "run" ]] && { log "identity check waived (VALIDATE_WORKTREE=run)"; _IDENTITY_PROVED=1; return 0; }
  resolver_is_overridden && { log "identity check waived (ROUTING TABLE resolver override)"; _IDENTITY_PROVED=1; return 0; }
  (( $(remaining_budget) <= 0 )) && { log "no budget left to check whether $cid reads this checkout"; return 0; }
  hostfile="${PROJECT_ROOT%/}/$REL"
  [[ -e "$hostfile" ]] || { log "$hostfile is gone — nothing to test $cid against"; return 0; }
  container_reads_checkout "$cid" "$hostfile" "${F:-$REL}"; rc=$?
  case "$rc" in
    0) log "container $cid reads this checkout: $_IDENTITY_REASON"; _IDENTITY_PROVED=1; return 0 ;;
    2) log "container $cid undecided for '$svc': $_IDENTITY_REASON"; return 2 ;;
  esac
  log "container $cid rejected for '$svc': $_IDENTITY_REASON"
  return 1
}

# The first candidate that reads this checkout, printed as `<id>|<proved>`.
# Empty when none does, and the STATUS then says which kind of "none" it was:
#
#   0  a candidate was accepted (its proof state is the second field)
#   1  every candidate was refused, and every refusal was established
#   2  at least one candidate could not be decided — the daemon answered the
#      listing and then stopped answering, say. Calling that `foreign` would
#      tell the agent its container belongs to another checkout, which is a
#      fact nothing here established.
#
# It runs inside a command substitution, so `printf` is the only way a value
# travels back; the status is the only way a second one does.
first_acceptable() {
  local svc="$1" cands="$2" c rc=0 undecided=0
  for c in $cands; do
    identity_ok "$svc" "$c"; rc=$?
    case "$rc" in
      0) printf '%s|%s' "$c" "$_IDENTITY_PROVED"; return 0 ;;
      2) undecided=1 ;;
    esac
  done
  (( undecided )) && return 2
  return 1
}

# ── The cause of a failed execution (plan D3) ────────────────────────────────
#
# Six named outcomes, and `unclassified` is the exhaustive bucket the spec
# demands (FR-006): Docker absent from the PATH and a socket permission refusal
# land in a named cause instead of falling through to a violation.
#
# It read "four" until `foreign` was added with plan D6, and "five" until `slow`
# was added with the resolution budget — which is the drift this comment audit
# exists to catch: a list that grew and a count that did not.
#
#   daemon         the daemon or the client could not be reached at all
#   slow           Docker was reached and did not answer inside the edit's
#                  budget. Distinct from `daemon` on purpose: "the daemon is
#                  down" is a claim about the world, and a stalled endpoint has
#                  not established it
#   nocontainer    no running container for this service
#   foreign        containers are running, and none of them reads THIS checkout
#                  (plan D6 — the refusal that keeps a shared stack from
#                  validating a file the agent did not write)
#   unclassified   the container is running and the call did not reach inside it
#   routing        the ROUTING TABLE called a verb before `svc`
#
# exec_in runs inside a command substitution (`out="$(_run …)"`), so the cause
# cannot travel back in a variable. It travels in a file, like the budget flag.
_CAUSE_FILE=""

cause_arm() {
  _CAUSE_FILE="$STATE_DIR/cause-$$"
  rm -f "$_CAUSE_FILE" 2>/dev/null || true
}

cause_set() { [[ -n "$_CAUSE_FILE" ]] && printf '%s' "$1" >"$_CAUSE_FILE"; return 0; }

cause_get() { [[ -n "$_CAUSE_FILE" && -f "$_CAUSE_FILE" ]] && cat "$_CAUSE_FILE" 2>/dev/null; return 0; }

cause_clear() { [[ -n "$_CAUSE_FILE" ]] && rm -f "$_CAUSE_FILE" 2>/dev/null; return 0; }

# ── Execution provenance ─────────────────────────────────────────────────────
#
# THE EXIT CODE CARRIES NO INFORMATION. `docker exec` never returns 125, and the
# three infrastructure failures that do occur all return 1 — the same code a
# linter returns when it found something. Measured on Docker 29.4.0 via
# OrbStack, macOS 25.5.0, 2026-09-17; the full table is stated ONCE, in the
# exit-code contract that heads `exec_in` below, because two copies of a
# measurement are two things free to drift apart.
#
# So the runner does not infer: it carries its own evidence. A per-invocation
# nonce is printed INSIDE the container immediately before the validator is
# handed control. Nonce back = the call reached inside and command resolution
# began; no nonce = the validator never started, whatever the code says.
#
# The nonce is NOT a prefix. Docker carries stdout and stderr separately and
# merges them in an order that is not stable across two runs of one unchanged
# command (research.md §2c), so detection looks for it ANYWHERE in the output.
#
# $0 of the wrapper shell is a second per-invocation marker: a shell prefixes
# its own `exec` diagnostic with $0, so `<argv0>: … not found` proves the
# SHELL said it, not the validator. Neither marker is a substring of the other.
#
# ── TWO RISKS ACCEPTED HERE, NOT DEFENDED AGAINST ────────────────────────────
#
# The nonce proves that the WRAPPER printed, not that the validator started, and
# two things can separate the two:
#
#   1. a container shipping a hostile `sh`. One that returns 7 for the probe
#      above, then prints its fourth argument — the nonce — and exits without
#      running the validator, is accepted as provenance. Nothing in a wrapper
#      whose own interpreter is the adversary can close that.
#   2. a process inside the container reading this invocation's argv (the nonce
#      is an argument, so `ps` shows it) and printing it on its own account.
#
# Both are ACCEPTED. The threat model of this hook is a developer's own stack —
# containers the developer built and started, running linters the developer
# chose — and the failure it exists to prevent is an infrastructure error read
# as a finding about the edited file, not an adversary inside the image. An
# attacker who controls `sh` in a routed container already controls the
# validator's output, its exit code, and the file system it reads: the nonce is
# the last thing that would matter. The same reasoning covers the argv reader.
#
# What is NOT accepted, and is why the nonce exists at all, is the accidental
# version of the same shape: Docker's own error text arriving where a finding
# was expected. That one happens weekly and is settled by evidence, above.
_NONCE=""
_NONCE_ARGV0=""
_NONCE_SEQ=0

# `$RANDOM__` would parse as a variable named RANDOM__, hence ${RANDOM}.
nonce_mint() {
  _NONCE_SEQ=$(( _NONCE_SEQ + 1 ))
  _NONCE="__voe_$$_${RANDOM}_${_NONCE_SEQ}__"
  _NONCE_ARGV0="voe-exec-$$-${RANDOM}-${_NONCE_SEQ}"
}

# Remove EXACTLY ONE occurrence — the first — of the exact injected value. A
# blanket removal would delete text from a validator whose own output happened
# to carry the nonce, which loses a finding rather than duplicating one.
strip_nonce_once() {
  local s="$1" n="$2"
  case "$s" in
    *"$n"*) printf '%s%s' "${s%%"$n"*}" "${s#*"$n"}" ;;
    *) printf '%s' "$s" ;;
  esac
}

# Does this service's container have a POSIX shell? Probed once per service, at
# resolution time, and cached beside the container id. A container with a
# working validator and no shell keeps being validated under the weaker rule of
# classify_degraded (FR-005a) rather than stopping being validated at all.
shell_cache() { printf '%s/shell-%s' "$STATE_DIR" "$1"; }

svc_has_shell() {
  local f; f="$(shell_cache "$1")"
  [[ -f "$f" ]] || return 0              # unknown: assume a shell, wrap as usual
  [[ "$(cat "$f" 2>/dev/null)" != "no" ]]
}

probe_shell() {
  local svc="$1" cid="$2" f rc=0
  f="$(shell_cache "$svc")"
  [[ -f "$f" ]] && return 0
  (( $(remaining_budget) <= 0 )) && return 0   # no time: assume a shell, decide nothing
  bounded docker exec -i "$cid" sh -c 'exit 7' >/dev/null 2>&1; rc=$?
  # Only 7 can come from a real shell, and only 126/127 prove there is none.
  # Any other code (1 = daemon trouble, 124 = the probe outran the budget)
  # leaves the question open rather than poisoning the cache with a "no" the
  # next session would inherit.
  case "$rc" in
    7)       printf 'yes' >"$f" 2>/dev/null || true ;;
    126|127) printf 'no'  >"$f" 2>/dev/null || true; log "service '$svc' has no POSIX shell — degraded classification" ;;
  esac
  return 0
}

# Hand the budget wrapper's output on — stdout and stderr merged, as with_budget
# wrote them — and remove its temporary file (FR-023). Used on every path where
# the call DID reach inside the container. The exit-code contract that output is
# read against is stated above `exec_in`, where the invocation happens.
drain_budget_out() {
  [[ -n "$BUDGET_OUT" && -f "$BUDGET_OUT" ]] || { BUDGET_OUT=""; return 0; }
  cat "$BUDGET_OUT"
  rm -f "$BUDGET_OUT"
  BUDGET_OUT=""
  return 0
}

# Throw the output away instead of handing it on — used on every path where the
# call did not reach inside the container, so Docker's own text cannot leak to
# the agent and no temporary file survives the edit (FR-002, FR-023).
budget_out_discard() {
  [[ -n "$BUDGET_OUT" ]] && rm -f "$BUDGET_OUT" 2>/dev/null
  BUDGET_OUT=""
  return 0
}

# `exec` replaces the shell, so the validator keeps the process, its exit code,
# its stdin and its signal behaviour. Arguments travel as positional parameters,
# never through a re-quoted command string, so a path containing spaces
# survives — measured on busybox ash, dash and bash.
#
# NO `--` BEFORE THE TOOL. An earlier draft of this wrapper injected one, to stop
# a tool name beginning with `-` being read as an option. Measured 2026-09-17 on
# the exact wrapper, and it is fatal:
#
#   alpine:3.20     busybox ash   exec -- echo hello   rc 0
#   debian:12-slim  dash          exec -- echo hello   rc 127
#                                 <argv0>: 1: exec: --: not found
#   ubuntu:24.04    dash          exec -- echo hello   rc 127   (identical)
#
# dash does not read `--` as an end-of-options marker for `exec`; it looks for a
# command literally named `--`. On any Debian- or Ubuntu-based image every
# invocation would return 127 with an argv0-prefixed diagnostic, which the
# classifier below would read as "tool not installed": one wiring warning per
# service, then permanent silence — strictly worse than the defect this feature
# exists to remove. A leading-dash tool name is refused at routing time instead,
# where the branch that wrote it can be named (see check/fix).
exec_wrapped() {
  local svc="$1" cid="$2"; shift 2
  if [[ -n "$_NONCE" ]] && svc_has_shell "$svc"; then
    with_budget docker exec -i "$cid" \
      sh -c 'printf "%s" "$1"; shift; exec "$@"' "$_NONCE_ARGV0" "$_NONCE" "$@"
    return $?
  fi
  with_budget docker exec -i "$cid" "$@"
  return $?
}

# Did this invocation reach inside the container?
#
# With a shell, the nonce settles it and nothing else is consulted.
#
# Without one (FR-005a) there is no provenance to read, and the rule used to be
# Docker's own error WORDING: text that did not look like a Docker message was
# taken as proof the validator had spoken. Docker's wording is not a contract.
# Measured 2026-09-17 on Docker 29.4.0, two failures of the client itself that
# match no known signature:
#
#   DOCKER_HOST=unix://<138 bytes>   Failed to initialize: unix socket path "…" is too long
#   an older client against this daemon   error during connect: …
#
# Both reached `classify_degraded`, which then handed Docker's own sentence to
# the agent as a finding about the edited file — the exact defect this feature
# exists to remove, walked back in through the degraded door.
#
# So the shell-less path no longer answers this question from text at all: with
# no provenance and a non-zero status, it says "not established" and lets
# exec_in ask Docker what STATE the service is in — the same probe it already
# runs for the shell-ful path, which costs one `docker ps` and does not depend
# on any wording. The text rule survives exactly one frame further down
# (classify_degraded), as the LAST resort, for the case the state probe cannot
# settle: the container is alive, reachable, and the call still failed.
exec_reached_inside() {
  local svc="$1" rc="$2" out=""
  (( rc == 0 )) && return 0
  svc_has_shell "$svc" || return 1
  [[ -n "$BUDGET_OUT" && -f "$BUDGET_OUT" ]] && out="$(cat "$BUDGET_OUT" 2>/dev/null)"
  case "$out" in *"$_NONCE"*) return 0 ;; esac
  return 1
}

# ── The exit-code contract (FR-020) ──────────────────────────────────────────
#
# MEASURED, never assumed. Docker 29.4.0 via OrbStack, macOS 25.5.0, 2026-09-17
# (specs/016-hook-exit-code-contract/research.md §1). One probe per row, against
# real containers on that host:
#
#   docker exec  container running, validator clean      0   —
#   docker exec  container running, validator found 3    3   the validator's output
#   docker exec  validator absent from the container   127   OCI runtime exec failed: … not found
#   docker exec  container stopped                       1   Error response from daemon: container … is not running
#   docker exec  container removed / never existed       1   Error response from daemon: No such container: …
#   docker exec  daemon unreachable                      1   failed to connect to the docker API …
#   docker run   --nonsense-flag                       125   a CLI usage error, on a command this runner never issues
#
# What stood here before said "125 = no running container, 124 = budget
# exceeded". Both halves were false and the first was the defect being repaired:
# `docker exec` NEVER returns 125, so the stale-container recovery keyed on it
# could not fire, while the three infrastructure failures that do occur all
# return 1 — the same code a validator returns when it found something. No
# remapping of codes repairs that, and neither does matching the error text: a
# validator's own output may legitimately carry a daemon-shaped line
# (research.md §2b, row 2, built to break exactly that rule).
#
# Platform caveat, because the table above is one platform's: Docker Desktop and
# Colima ship the same CLI binary, which is the reason to EXPECT the same codes,
# but neither was measured. Nothing below depends on the expectation — the
# classification rests on the nonce, not on any code in this table.
#
# So exec_in hands back codes that need no interpretation:
#
#   any code, nonce present  the VALIDATOR's own code, 124/126/127 included:
#                            those are its signals, and the runner does not
#                            claim them (FR-003)
#   124, budget              recognised through _BUDGET_FLAG and never through
#                            the code, precisely because a validator may also
#                            exit 124 (see with_budget)
#   125                      the runner's OWN synthetic code; `docker exec`
#                            cannot produce it. It means "nothing ran", and WHY
#                            is in the cause file, never in the code: daemon,
#                            nocontainer, foreign, unclassified, routing
#
# exec_in SERVICE CMD...
#
# Cache invalidation and recovery live HERE, not in the classifier (FR-017). A
# ROUTING TABLE branch that formats before it validates runs `fix` first, and
# `fix` discards its result by design; with the recovery in `check` that branch
# left a dead identifier cached for the validator that follows it.
# ── The container cache, keyed by SERVICE AND PROJECT ────────────────────────
#
# A cached id used to be read back on the strength of the service name alone,
# which quietly made the cache outrank the resolution that produced it: change
# the Compose file's `name:`, or the exported COMPOSE_PROJECT_NAME, and every
# later edit still executed in the OLD project's container. The Compose
# fingerprint guards the NAME; nothing guarded the container that name produced.
# So the project is stored beside the id and compared on every read.
#
# `compose_project` costs no Docker call on the hot path: the exported variable
# short-circuits it, and otherwise the name cache answers from file contents
# alone. Compose is asked again only when the fingerprint moved, which is
# exactly when the answer may have changed.
#
# Dropping an id also drops the shell answer probed for it (FR-005a). They are
# facts about ONE container, not about the service: a shell-less replacement
# inheriting `shell=yes` gets wrapped in a `sh -c` it cannot run, so its working
# validator is never attempted again — a permanent silence, one probe away.
cid_cache_file() { printf '%s/cid-%s' "$STATE_DIR" "$1"; }

cid_cache_drop() { rm -f "$(cid_cache_file "$1")" "$(shell_cache "$1")" 2>/dev/null || true; return 0; }

cid_cache_write() {
  printf '%s\n%s\n' "$(compose_project)" "$2" >"$(cid_cache_file "$1")" 2>/dev/null || true
  return 0
}

cid_cache_read() {
  local svc="$1" f proj id now
  f="$(cid_cache_file "$svc")"
  [[ -f "$f" ]] || return 1
  proj="$(sed -n '1p' "$f" 2>/dev/null)"
  id="$(sed -n '2p' "$f" 2>/dev/null)"
  # A one-line file is an older runner's cache, written before the project was
  # recorded: unverifiable, so it is dropped rather than trusted.
  [[ -n "$id" ]] || { cid_cache_drop "$svc"; return 1; }
  now="$(compose_project)"
  if [[ "$proj" != "$now" ]]; then
    log "the cached container for '$svc' was resolved under project '$proj', now '$now' — dropping it"
    cid_cache_drop "$svc"
    return 1
  fi
  printf '%s' "$id"
  return 0
}

# The tail shared by every path where the wrapper returned non-zero, no
# provenance came back, and Docker's own listing has just shown the container
# alive and reachable.
#
# With a shell, that combination is an infrastructure verdict: the nonce says
# the call did not get inside, and what came back is not the validator's.
# Without one, no provenance can exist (FR-005a) and the state probe has said
# everything it can, so the output is handed to check() for the weaker,
# LAST-RESORT text rule of classify_degraded — which is the only place Docker's
# wording is still consulted.
finish_unproved() {
  local svc="$1" rc="$2"
  if svc_has_shell "$svc"; then
    budget_out_discard
    cause_set unclassified
    return 125
  fi
  log "degraded: '$svc' has no POSIX shell and its container is alive — classifying by its output"
  drain_budget_out
  return "$rc"
}

exec_in() {
  local svc="$1"; shift
  local cid="" rc=0 cands="" prc=0 sel="" proved=0 frc=0

  cid="$(cid_cache_read "$svc")" || cid=""

  # Hot path: one `docker exec` on the cached container id, no lookup at all.
  if [[ -n "$cid" ]]; then
    # A cid cached by an older runner carries no shell answer; probing it here
    # costs one call once, never per edit.
    probe_shell "$svc" "$cid"
    exec_wrapped "$svc" "$cid" "$@"; rc=$?
    budget_was_killed && { drain_budget_out; return "$rc"; }
    exec_reached_inside "$svc" "$rc" && { drain_budget_out; return "$rc"; }

    # Nothing is known yet. The output stays on disk until the cause is decided:
    # every branch below either drains it to the agent or discards it, and the
    # one branch that keeps it is the shell-less one, where it is all there is.
    if (( $(remaining_budget) <= 0 )); then
      # No time for the probe. FR-010: not validated, cause unknown — never a
      # guess, and never a violation.
      log "no budget left to establish why '$svc' did not run"
      budget_out_discard
      cause_set unclassified
      return 125
    fi

    # ONE label-filtered `docker ps`, read as a SET and consumed whole (plan D3).
    cands="$(lookup_candidates "$svc")"; prc=$?
    if (( prc == 124 )); then
      log "docker ps for '$svc' outran the edit's budget"
      budget_out_discard
      cause_set slow
      return 125
    fi
    if (( prc != 0 )); then
      # FR-008: a re-resolution would ask the same unreachable daemon, so it is
      # not attempted. This is the only place that decision is taken.
      log "docker ps failed for '$svc' — daemon unreachable or client refused"
      budget_out_discard
      cause_set daemon
      return 125
    fi
    if [[ -z "${cands//[$'\t\n\r ']/}" ]]; then
      log "no running container for '$svc' — dropping the cached id"
      cid_cache_drop "$svc"
      budget_out_discard
      cause_set nocontainer
      return 125
    fi
    if cands_contain "$cands" "$cid"; then
      finish_unproved "$svc" "$rc"
      return $?
    fi

    # The container was replaced, possibly among several on a scaled service.
    # Take the first candidate that reads THIS checkout (plan D6) and retry
    # exactly once.
    sel="$(first_acceptable "$svc" "$cands")"; frc=$?
    cid="${sel%%|*}"; proved="${sel##*|}"
    if [[ -z "$cid" ]]; then
      cid_cache_drop "$svc"
      budget_out_discard
      if (( frc == 2 )); then
        log "the replacement container(s) for '$svc' could not be inspected"
        cause_set unclassified
      else
        log "the replacement container(s) for '$svc' do not read this checkout"
        cause_set foreign
      fi
      return 125
    fi
    # Only a PROVED identity is written down: a check skipped for want of budget
    # buys this edit a container, never the next edit's hot path.
    cid_cache_drop "$svc"
    if [[ "$proved" == "1" ]]; then cid_cache_write "$svc" "$cid"
    else log "container $cid used for '$svc' without a proof of identity — not cached"; fi
    log "container for '$svc' was replaced — retrying once on $cid"
    probe_shell "$svc" "$cid"
    exec_wrapped "$svc" "$cid" "$@"; rc=$?
    budget_was_killed && { drain_budget_out; return "$rc"; }
    exec_reached_inside "$svc" "$rc" && { drain_budget_out; return "$rc"; }
    log "the replacement container for '$svc' did not run the validator either"
    finish_unproved "$svc" "$rc"
    return $?
  fi

  # Nothing has been invoked yet on this path, so an exhausted budget is the
  # `unspent` sentence and not the `slow` one: Docker was never asked, and
  # saying it did not answer would assert a cause nothing established (FR-022).
  # check() reads the sentinel before it reads any cause.
  if (( $(remaining_budget) <= 0 )); then
    log "the edit's budget was spent before '$svc' could be resolved"
    budget_flag_raise unspent
    return 125
  fi

  cands="$(lookup_candidates "$svc")"; prc=$?
  if (( prc == 124 )); then
    log "docker ps for '$svc' outran the edit's budget"
    cause_set slow
    return 125
  fi
  if (( prc != 0 )); then
    log "docker ps failed for '$svc' — daemon unreachable or client refused"
    cause_set daemon
    return 125
  fi
  [[ -z "${cands//[$'\t\n\r ']/}" ]] && { log "no running container for '$svc'"; cause_set nocontainer; return 125; }
  # plan D6: only a container that reads THIS checkout is cached and used.
  sel="$(first_acceptable "$svc" "$cands")"; frc=$?
  cid="${sel%%|*}"; proved="${sel##*|}"
  if [[ -z "$cid" ]]; then
    if (( frc == 2 )); then
      log "no candidate container for '$svc' could be inspected"
      cause_set unclassified
    else
      log "no candidate container for '$svc' reads this checkout"
      cause_set foreign
    fi
    return 125
  fi
  if [[ "$proved" == "1" ]]; then cid_cache_write "$svc" "$cid"
  else log "container $cid used for '$svc' without a proof of identity — not cached"; fi
  probe_shell "$svc" "$cid"

  exec_wrapped "$svc" "$cid" "$@"; rc=$?
  budget_was_killed && { drain_budget_out; return "$rc"; }
  exec_reached_inside "$svc" "$rc" && { drain_budget_out; return "$rc"; }
  finish_unproved "$svc" "$rc"
  return $?
}

# ── Routing verbs — the vocabulary the ROUTING TABLE is written in ───────────
#   svc NAME       target compose service (required, first)
#   strip PREFIX   drop a path prefix so the container sees its own relative path
#   fix  CMD...    best-effort auto-fix; failures never reach the agent
#   check CMD...   validation; a non-zero exit becomes agent feedback
#   skip           explicitly declare this path as not validated
_SVC=""; _SKIP=0; _ROUTED=0; _VIOLATION=""; F=""; REL=""; WARNING=""; DRY=0

# Run the ROUTING TABLE for its ROUTING DECISION only — which service, and which
# path that service would be given — and invoke nothing. `--doctor` uses it to
# ask the table a question the table cannot be asked directly: it maps a path to
# a service, never a service to a path, so the only honest way to obtain a
# representative path per service is to run the table over paths that really
# exist and keep the first one that lands on each service.
#
# It is NOT `DRY`: DRY=1 still walks into `_run`, which prints `would run: …` to
# stderr, and `fix` under DRY discards stdout only — one such line per scanned
# file would be interleaved with the diagnostic. This flag stops before any of
# that, leaving `svc`, `strip` and `skip` — the three verbs that carry the
# decision — to do exactly what they do on a real edit.
_ROUTE_PROBE=0

svc()   { _SVC="$1"; _ROUTED=1; F="${F:-$REL}"; }
strip() { F="${REL#$1}"; }
skip()  { _SKIP=1; _ROUTED=1; }

# Shared by fix/check. Echoes output, returns the container exit code.
_run() {
  local tool="$1"
  if [[ -z "$_SVC" ]]; then
    log "routing error: '$tool' called before svc"
    cause_set routing
    return 125
  fi
  if (( DRY )); then
    printf '  would run: docker exec <%s> %s\n' "$_SVC" "$*" >&2
    return 0
  fi
  # A client that is not there is the same outage as a daemon that is not there:
  # session-wide, no service at fault, and not worth one warning per service.
  # FR-006 names it rather than letting it fall through to a violation.
  command -v docker >/dev/null 2>&1 || { log "docker not on PATH"; cause_set daemon; return 125; }
  exec_in "$_SVC" "$@"
}

# A tool name beginning with `-` is a ROUTING TABLE mistake, and it is refused
# by name here rather than mis-parsed inside a container. The portable wrapper
# has no end-of-options marker to hide behind: `--` is fatal on dash (see
# exec_wrapped), so there is nowhere left to absorb this quietly — and absorbing
# it quietly is what produced a shell diagnostic the classifier then read as
# "tool not installed". Returns 0 when it refused, 1 when the name is fine.
refuse_dash_tool() {
  local tool="$1"
  case "$tool" in -*) ;; *) return 1 ;; esac
  log "routing error: tool '$tool' starts with '-' (branch matching $REL, service '${_SVC:-<none>}')"
  warn_once "routing-${_SVC:-none}-$tool" \
    "[validate] the ROUTING TABLE branch matching $REL runs \`$tool\`, whose name begins
with \`-\`, so a shell inside the container would read it as an option and not as
a command. $REL was NOT validated. Name the real binary in
.agents/hooks/validate-on-edit.sh, or invoke it through \`sh -c '…' _ \"\$F\"\`." || true
  return 0
}

fix() {
  _ROUTED=1
  (( _ROUTE_PROBE )) && return 0
  refuse_dash_tool "$1" && return 0
  (( DRY )) && { _run "$@" >/dev/null; return 0; }
  local out rc=0
  nonce_mint
  budget_flag_arm
  # Armed here too, although `fix` never reads it: an unarmed cause file would
  # leave a previous branch's verdict in place for the `check` that follows.
  # The RECOVERY this path performs is not optional and lives in exec_in.
  cause_arm
  out="$(_run "$@")" || rc=$?
  out="$(strip_nonce_once "$out" "$_NONCE")"
  (( rc != 0 )) && log "fix '$1' rc=$rc (non-blocking): ${out:0:200}"
  cause_clear
  return 0
}

# ── The decision table (plan D2) ─────────────────────────────────────────────
#
#   killed by the runner's own sentinel        budget warning
#   rc 0                                       silence — no measured
#                                              infrastructure failure returns 0,
#                                              so provenance adds nothing here
#   exec_in named a cause                      the warning for THAT cause (D3):
#                                              daemon, nocontainer, foreign,
#                                              routing, or unclassified
#   the service has no POSIX shell             the degraded rule of FR-005a,
#                                              and the agent is told so
#   nonce absent                               infrastructure warning
#   nonce present, rc 126/127, shell's own
#     diagnostic after stripping               wiring warning
#   nonce present, rc != 0, output remains     VIOLATION carrying that output
#   nonce present, rc != 0, nothing remains    VIOLATION naming the code
#
# Emptiness is tested AFTER stripping, never before: the nonce is itself output,
# and testing before it would make every silent validator look like it spoke.
#
# A validator may legitimately exit 124, 126 or 127 as its own signal, so the
# runner claims those codes only when the accompanying evidence shows the runner
# (or the wrapper shell) produced them. And silence is a violation, not nothing:
# `grep -q` and `cmp -s` are legitimate routing-table entries that speak through
# their exit code alone.

# Did the WRAPPER SHELL — not the validator — refuse to run the tool? The shell
# prefixes its `exec` diagnostic with $0, and $0 is a value this runner invented
# for this one invocation, so a validator cannot forge it. The wording after the
# prefix differs per shell, which is why nothing here matches on it. Measured
# 2026-09-17, one line each:
#   busybox ash (alpine:3.20)      <argv0>: exec: line 0: <tool>: not found
#   dash (debian:12-slim, ubuntu)  <argv0>: 1: exec: <tool>: not found
#   bash 3.2 (host)                <argv0>: line 0: exec: <tool>: not found
is_shell_exec_diagnostic() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"                 # left-trim
  case "$s" in "$_NONCE_ARGV0: "*) ;; *) return 1 ;; esac
  case "$s" in
    *"not found"*|*"Permission denied"*|*"permission denied"*|*"cannot execute"*) return 0 ;;
  esac
  return 1
}

# Docker's own failure wording. The LAST resort on the shell-less path, reached
# only after the state probe has said the container is alive and reachable: it
# is exactly the text-matching rule FR-001 forbids as a primary test, which is
# why nothing else consults it and why the probe now runs first. This list is
# knowingly incomplete — `Failed to initialize: unix socket path … is too long`
# and `error during connect …` are two measured members it does not carry — and
# that is survivable ONLY because a wording it does not recognise now reaches
# here with the container already shown alive.
is_docker_error() {
  case "$1" in
    *"Error response from daemon:"*) return 0 ;;
    *"OCI runtime exec failed"*) return 0 ;;
    *"failed to connect to the docker API"*) return 0 ;;
    *"Cannot connect to the Docker daemon"*) return 0 ;;
    *"permission denied while trying to connect to the Docker daemon"*) return 0 ;;
  esac
  return 1
}

_degraded_note() {
  printf '%s' "Classification for \`$_SVC\` is DEGRADED: its container has no POSIX shell, so
the runner cannot prove whether the validator ran and is matching Docker's own
error wording instead. Add a shell to that image to restore full classification."
}

# FR-005a: no provenance available. Weaker, and the agent is told so.
classify_degraded() {
  local tool="$1" rc="$2" out="$3"
  if is_docker_error "$out"; then
    if (( rc == 126 || rc == 127 )); then
      log "degraded: '$tool' not runnable in '$_SVC' (rc=$rc)"
      warn_once "wiring-$_SVC-$tool" \
        "[validate] \`$tool\` could not be run in the \`$_SVC\` container, so $REL was not
validated. Add it to that service's dependencies, or drop it from the ROUTING
TABLE in .agents/hooks/validate-on-edit.sh.
$(_degraded_note)" || true
      return 0
    fi
    log "degraded: docker error for '$_SVC' (rc=$rc)"
    warn_once "nocontainer-$_SVC" \
      "[validate] service \`$_SVC\` could not be reached, so $REL was not validated.
Start the stack (\`make up\`) to re-enable on-edit validation.
$(_degraded_note)" || true
    return 0
  fi
  if [[ -z "${out//[$'\t\n\r ']/}" ]]; then
    _VIOLATION="[validate] $REL — $tool (exit $rc)

The validator exited $rc and printed nothing."
    return 0
  fi
  _VIOLATION="[validate] $REL — $tool (exit $rc)

$out"
  return 0
}

# The warning the agent receives when nothing ran, keyed by CAUSE and not by
# service (FR-009). A daemon or client outage is not a property of any one
# service, so it warns once for the whole session; everything else is per
# service. No key is a prefix or a synonym of another, so a daemon outage cannot
# later silence a genuine missing-container warning for a service — which is the
# suppression collision the spec calls out by name.
warn_cause() {
  local tool="$1" cause="$2"
  case "$cause" in
    daemon)
      warn_once "daemon" \
        "[validate] Docker could not be reached, so $REL was not validated. The daemon is
down, the client is not on the PATH, or the socket refused it — no service is at
fault, and the runner did not try to resolve a container, because resolution
asks the same Docker. This is reported once for the whole session." || true
      ;;
    slow)
      # Its own key, and session-wide like `daemon`: a stalled endpoint is not a
      # property of any one service either. It is NOT `daemon`, because nothing
      # here established that the daemon is down — only that it did not answer
      # in time, which a loaded machine and a cold VM also produce.
      warn_once "slow" \
        "[validate] Docker did not answer inside the ${VALIDATE_BUDGET_S}s budget for this edit, so
$REL was not validated. The runner stopped waiting rather than let an on-edit
hook stall: a loaded machine, a cold daemon or a remote endpoint all look the
same from here. Raise VALIDATE_BUDGET_S if this recurs. Reported once for the
whole session." || true
      ;;
    nocontainer)
      warn_once "nocontainer-$_SVC" \
        "[validate] service \`$_SVC\` has no running container, so $REL was not validated.
Start the stack (\`make up\`) to re-enable on-edit validation." || true
      ;;
    foreign)
      # plan D6. Its own key: a checkout mismatch is neither a dead daemon nor a
      # stopped service, and telling the agent to run `make up` would be wrong.
      warn_once "foreign-$_SVC" \
        "[validate] the running \`$_SVC\` container does not read this checkout's copy of
$REL, so the file was NOT validated. The path it would read is served by another
directory or by a named volume, so a pass or a fail there would describe a file
you did not write. Start this checkout's own stack, or set VALIDATE_WORKTREE=run
if one stack is shared on purpose." || true
      ;;
    routing)
      warn_once "routing-nosvc-$tool" \
        "[validate] the ROUTING TABLE branch matching $REL runs \`$tool\` before naming a
service with \`svc\`, so $REL was not validated. Add \`svc <name>\` first in
.agents/hooks/validate-on-edit.sh." || true
      ;;
    *)
      # The exhaustive bucket (FR-006). An unforeseen cause degrades to a
      # warning that says so, never to a violation about the edited file.
      warn_once "unclassified-$_SVC" \
        "[validate] \`$tool\` did not run inside the \`$_SVC\` container, so $REL was not
validated, and the runner could not establish why: Docker answered, a container
for that service is running, and the call still did not reach inside it. Run
\`.agents/hooks/validate-on-edit.sh --doctor\` and check the container's health." || true
      ;;
  esac
  return 0
}

check() {
  _ROUTED=1
  (( _ROUTE_PROBE )) && return 0
  [[ -n "$_VIOLATION" ]] && return 0   # fail-fast: one violation per edit is enough
  local out rc=0 tool="$1" stripped="" ran=0 cause=""
  refuse_dash_tool "$tool" && return 0
  nonce_mint
  budget_flag_arm
  cause_arm
  out="$(_run "$@")" || rc=$?
  (( DRY )) && return 0
  cause="$(cause_get)"
  cause_clear

  # 1. The runner killed it, or never started it. Its own sentinel, not the exit
  #    code — and the two are not the same sentence (FR-022).
  if budget_was_killed; then
    if [[ "$(budget_reason)" == "unspent" ]]; then
      log "budget already spent before '$tool' ran on $REL"
      warn_once "budget-$_SVC-$tool" \
        "[validate] the ${VALIDATE_BUDGET_S}s budget for this edit was already spent before \`$tool\`
could start on $REL, so nothing was invoked and the file was not validated.
Earlier branches of the ROUTING TABLE consumed it. Raise VALIDATE_BUDGET_S, or
move a slower step to CI." || true
    else
      log "budget exceeded (${VALIDATE_BUDGET_S}s): $tool on $REL"
      warn_once "budget-$_SVC-$tool" \
        "[validate] \`$tool\` did not finish inside the ${VALIDATE_BUDGET_S}s budget on $REL and was
killed, so the file was not validated. The runner does not know why: a genuinely
slow tool, a cold start, or a loaded machine all look the same from here. Raise
VALIDATE_BUDGET_S, or move the tool to CI if it is slow every time." || true
    fi
    return 0
  fi

  # 2. Success needs no provenance: no infrastructure failure measured here
  #    returns 0, so there is nothing a nonce could add.
  (( rc == 0 )) && return 0

  # 3. Nothing ran, and exec_in established WHY from one `docker ps` read as a
  #    set (plan D3). It also did the recovery: this branch only speaks.
  if [[ -n "$cause" ]]; then
    log "no execution for '$tool' in service '$_SVC' (rc=$rc, cause=$cause)"
    warn_cause "$tool" "$cause"
    return 0
  fi

  # 4. No shell in that container: no provenance can exist (FR-005a).
  if ! svc_has_shell "$_SVC"; then
    classify_degraded "$tool" "$rc" "$out"
    return 0
  fi

  case "$out" in *"$_NONCE"*) ran=1 ;; esac
  stripped="$(strip_nonce_once "$out" "$_NONCE")"

  # 5. Belt and braces: the call did not reach inside and exec_in named no
  #    cause. Nothing should reach here — exec_in answers that question for
  #    every path — so it degrades to the unclassified warning rather than to a
  #    violation carrying Docker's text.
  if (( ! ran )); then
    log "no provenance and no cause for '$tool' in service '$_SVC' (rc=$rc): ${out:0:200}"
    warn_cause "$tool" unclassified
    return 0
  fi

  # 6. The wrapper shell itself refused to run the tool.
  if (( rc == 126 || rc == 127 )) && is_shell_exec_diagnostic "$stripped"; then
    log "tool '$tool' not runnable in service '$_SVC' (rc=$rc)"
    warn_once "wiring-$_SVC-$tool" \
      "[validate] \`$tool\` is not installed in the \`$_SVC\` container, so $REL was not
validated. Add it to that service's dependencies, or drop it from the ROUTING
TABLE in .agents/hooks/validate-on-edit.sh." || true
    return 0
  fi

  # 7. It ran and it failed. Silence is a verdict too.
  if [[ -z "${stripped//[$'\t\n\r ']/}" ]]; then
    log "$tool rc=$rc with no output on $REL"
    _VIOLATION="[validate] $REL — $tool (exit $rc)

The validator exited $rc and printed nothing."
    return 0
  fi

  _VIOLATION="[validate] $REL — $tool (exit $rc)

$stripped"
  return 0
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

# Should validation run inside this linked worktree? (FR-015, FR-016)
#
# The old rule skipped exactly one shape — COMPOSE_PROJECT_NAME exported — on
# the grounds that the name otherwise came from the worktree's OWN directory, so
# a worktree could only ever resolve its own stack. D5 removes that ground: the
# name now comes from the Compose file the worktree shares with its main
# checkout, so the dangerous share is a declared `name:` with no variable
# exported, and the old rule answers "validate" there — against the main
# checkout's bind mount, on a file the agent did not write.
#
# So the decision is no longer taken here from the environment. `auto` defers it
# to the checkout-identity test at resolution time (plan D6): in a linked
# worktree, validate when the resolved container reads THIS worktree, and warn
# otherwise. The two explicit answers are unchanged and still win outright —
# `skip` never validates, `run` validates and waives the identity test, which is
# the opt-out FR-015 requires for a deliberately shared stack.
worktree_decision() {
  case "$VALIDATE_WORKTREE" in
    run)  printf 'run' ;;
    skip) printf 'skip' ;;
    *)    printf 'verify' ;;
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

  # The two sentinels are how a verdict escapes a command substitution. They are
  # per-process and re-armed per verb, so they are consumed by now; removing
  # them here keeps the state directory to the caches it is meant to hold.
  cause_clear
  [[ -n "$_BUDGET_FLAG" ]] && rm -f "$_BUDGET_FLAG" 2>/dev/null

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

# ── Diagnostic helpers — used by `--doctor` only ─────────────────────────────
#
# ── 1. The two spellings of the project root ─────────────────────────────────
#
# `find_project_root` takes git's top-level, and git answers it PHYSICALLY, with
# every symlink resolved. The hook payload carries whatever spelling the agent's
# editor used, which on a checkout reached through a symlink is the unresolved
# one. The hook entry then compares the two AS STRINGS ("$PROJECT_ROOT/"*) and,
# finding no match, returns through `silent` — the arm reserved for files it
# deliberately does not route. Every edit is unvalidated and the agent is told
# nothing at all.
#
# That defect is DECLARED AND UNFIXED (GRV-symlinked-project-path-makes-7d96)
# and this is not the fix. This is the thing that makes it visible, because the
# consumer's only symptom today is silence, and silence is exactly what a
# correctly installed hook produces on a clean file.
#
# Measured 2026-09-17 on this machine (macOS 25.5.0, git 2.x), a throwaway
# repository at /tmp/…/real reached through the symlink /tmp/…/link:
#
#   git -C /tmp/…/link/sub rev-parse --show-toplevel  ->  /private/tmp/…/real
#   cd /tmp/…/link/sub && pwd                         ->  /tmp/…/link/sub
#   cd /tmp/…/link/sub && pwd -P                      ->  /private/tmp/…/real/sub
#
#   payload  /tmp/…/link/sub/app.txt   against root  /private/tmp/…/real
#   -> the prefix test fails, and the runner takes the silent arm.
#
# Both halves of that pair come from the same place here. The RESOLVED spelling
# is what the runner itself uses; the spelling AS REACHED is the logical cwd the
# diagnostic was invoked from — the same kind of value an editor sends, produced
# by whatever navigated into this directory, and the only unresolved spelling a
# read-only command can honestly obtain. When the two lead to the same directory
# and differ as strings, this root has two spellings and one of them is skipped.
#
# Prints "<resolved>TAB<as reached>"; the two fields are identical when there is
# only one spelling, which is the common case and is reported in one line.
doctor_root_spellings() {
  local canon phys_cwd logi_cwd tail lroot back
  canon="$(path_canon "$PROJECT_ROOT")" || canon="$PROJECT_ROOT"
  phys_cwd="$(pwd -P 2>/dev/null)"
  logi_cwd="$(pwd -L 2>/dev/null)"
  lroot=""
  if [[ -n "$phys_cwd" && -n "$logi_cwd" && "$phys_cwd" != "$logi_cwd" ]]; then
    case "$phys_cwd" in
      "$canon")
        lroot="$logi_cwd" ;;
      "$canon"/*)
        tail="${phys_cwd#"$canon"}"
        case "$logi_cwd" in *"$tail") lroot="${logi_cwd%"$tail"}" ;; esac ;;
    esac
  fi
  [[ -z "$lroot" ]] && lroot="$canon"
  # A derived spelling that does not lead back to the same directory is not a
  # spelling of this root at all. Report one spelling rather than a claim.
  if [[ "$lroot" != "$canon" ]]; then
    back="$(path_canon "$lroot")" || back=""
    [[ "$back" == "$canon" ]] || lroot="$canon"
  fi
  printf '%s\t%s' "$canon" "$lroot"
}

# ── 2. Can each routed service actually see the file it would be given? ──────
#
# The check nobody writes and everybody needs. A service whose container cannot
# see the path the routing table hands it validates NOTHING, whatever else in
# this diagnostic is green — a `strip` that removes the wrong prefix, a service
# mounting only part of the repository, a routed path that never existed in the
# image. Today the only way to learn that is to edit a file and notice that
# nothing happened, which is indistinguishable from a clean file.
#
# doctor_candidate_files — repo-relative paths that really exist, bounded.
# `git ls-files` when this is a work tree (it already excludes what git
# ignores), `find` otherwise. The cap is what keeps `--doctor` a human CLI
# command on a large checkout: the scan stops as soon as every routed service
# has a representative, so the cap is only reached when some service has none.
DOCTOR_SCAN_CAP="${DOCTOR_SCAN_CAP:-4000}"

doctor_candidate_files() {
  if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT" ls-files 2>/dev/null
    return 0
  fi
  ( cd "$PROJECT_ROOT" 2>/dev/null && find . -type f 2>/dev/null | sed 's|^\./||' )
  return 0
}

# doctor_representatives SERVICES — one line per service, `svc TAB rel TAB given`.
# `rel` is a file in this checkout that the ROUTING TABLE routes to `svc`, and
# `given` is the path the table would hand the validator, after `strip`. A
# service with no line has no representative, which is reported as such and
# never guessed at.
doctor_representatives() {
  local wanted="$1" found="" list="" rel="" n=0
  local _keep_REL="$REL" _keep_F="$F" _keep_SVC="$_SVC" _keep_SKIP="$_SKIP" _keep_ROUTED="$_ROUTED"
  _ROUTE_PROBE=1
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    n=$(( n + 1 ))
    (( n > DOCTOR_SCAN_CAP )) && break
    is_excluded_path "$rel" && continue
    [[ -f "$PROJECT_ROOT/$rel" ]] || continue
    REL="$rel"; F="$REL"; _SVC=""; _SKIP=0; _ROUTED=0
    route
    [[ -n "$_SVC" ]] || continue
    (( _SKIP )) && continue
    case " $wanted " in *" $_SVC "*) ;; *) continue ;; esac
    case "$found" in *"|$_SVC|"*) continue ;; esac
    found="$found|$_SVC|"
    list="$list$_SVC	$rel	$F
"
    # Every wanted service answered: stop walking the checkout.
    local s all=1
    for s in $wanted; do case "$found" in *"|$s|"*) ;; *) all=0 ;; esac; done
    (( all )) && break
  done <<EOF
$(doctor_candidate_files)
EOF
  _ROUTE_PROBE=0
  REL="$_keep_REL"; F="$_keep_F"; _SVC="$_keep_SVC"; _SKIP="$_keep_SKIP"; _ROUTED="$_keep_ROUTED"
  printf '%s' "$list"
}

# doctor_container_path CID HOSTFILE GIVEN — the path inside CID at which this
# checkout's HOSTFILE lives, or empty when the container's facts could not be
# read.
#
# An absolute GIVEN is taken as given. A relative one is resolved from the
# MOUNTS rather than from the prefix arithmetic the routing table performs in
# its own `check` line, because that arithmetic is invisible from here: a branch
# writing `check sh -c '…' _ "/work/$F"` composes the container path inside the
# command, where no diagnostic can read it. The mounts answer the question that
# is actually worth asking — where in this container does THIS checkout's file
# live — and a container that cannot see that path cannot validate the file
# under any spelling. Falling back to the working directory, for a container
# with no bind holding the file, is the same assumption container_reads_checkout
# already makes for a relative path.
doctor_container_path() {
  local cid="$1" hostfile="$2" given="$3"
  local facts mounts wd canon_file canon_src line m_type m_src m_dest
  local best_src="" best_dest="" cand=""
  case "$given" in /*) printf '%s' "$given"; return 0 ;; esac
  facts="$(container_facts "$cid")"
  [[ -n "$facts" ]] || return 1
  wd="$(printf '%s' "$facts" | sed -n '1p')"
  mounts="$(printf '%s' "$facts" | sed -n '2,$p')"
  canon_file="$(path_canon "$hostfile")" || canon_file="$hostfile"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    m_type="${line%%|*}"; m_src="${line#*|}"; m_dest="${m_src#*|}"; m_src="${m_src%%|*}"
    [[ "$m_type" == "bind" ]] || continue
    canon_src="$(path_canon "$m_src")" || canon_src="$m_src"
    path_within "$canon_file" "$canon_src" || continue
    if [[ ${#canon_src} -gt ${#best_src} ]]; then best_src="$canon_src"; best_dest="$m_dest"; fi
  done <<EOF
$mounts
EOF
  if [[ -n "$best_src" ]]; then
    if [[ "$canon_file" == "$best_src" ]]; then
      cand="$best_dest"
    else
      cand="${best_dest%/}/${canon_file#"${best_src%/}/"}"
    fi
    printf '%s' "$cand"
    return 0
  fi
  cand="${wd:-/}"
  printf '%s' "${cand%/}/$given"
  return 0
}

# doctor_file_visible CID PATH — does the container see a regular file there?
# REPORTS, never decides: `--doctor` says what it found and changes nothing
# about whether the hook runs. One `docker exec` per routed service.
#
#   0  visible
#   1  the container answered, and the file is not there
#   2  the call itself did not come back with an answer we can attribute
doctor_file_visible() {
  local cid="$1" p="$2" rc=0
  bounded docker exec -i "$cid" test -f "$p" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  return 2
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
      # The two spellings of that root, when this checkout has two. A clean
      # setup gets one line and no noise; a symlinked one gets the consequence
      # spelled out, because its only other symptom is silence.
      local _sp _sp_res _sp_seen
      _sp="$(doctor_root_spellings)"
      _sp_res="${_sp%%	*}"; _sp_seen="${_sp#*	}"
      if [[ "$_sp_res" == "$_sp_seen" ]]; then
        printf 'spelling  : one — the resolved root is also the root as reached from here.\n'
      else
        printf 'spelling  : TWO — this project root has two spellings, and they disagree.\n'
        printf '            resolved   : %s\n' "$_sp_res"
        printf '            as reached : %s\n' "$_sp_seen"
        printf '            The runner uses the resolved one and compares the edited path to it\n'
        printf '            as a string, so an edit arriving with the unresolved spelling is read\n'
        printf '            as sitting outside the project and is SKIPPED IN SILENCE — no\n'
        printf '            warning, no violation, indistinguishable from a clean file.\n'
        printf '            Declared and unfixed: GRV-symlinked-project-path-makes-7d96.\n'
      fi
      printf 'compose   : %s\n' "$(compose_project)"
      # FR-018: the resolution is printed, never inferred.
      if resolver_is_overridden; then
        printf 'name from : a ROUTING TABLE override of compose_project (it also waives the\n'
        printf '            checkout-identity test)\n'
      else
        printf 'name from : %s\n' "$(compose_source)"
      fi
      if [[ -n "$(compose_files)" ]]; then
        printf 'compose files:\n'
        printf '%s\n' "$(compose_files)" | sed 's/^/  /'
      fi
      printf 'not visible from a hook: a file list (-f) or a project name (-p) given on the\n'
      printf '            command line when the stack was started.\n'
      if in_linked_worktree; then
        printf 'worktree  : linked — %s (VALIDATE_WORKTREE=%s)\n' "$(worktree_decision)" "$VALIDATE_WORKTREE"
        [[ "$(worktree_decision)" == "verify" ]] && \
          printf '            each container is checked at resolution time for reading THIS worktree.\n'
      else
        printf 'worktree  : main checkout\n'
      fi
      printf 'timeout   : %s\n' "${TIMEOUT_BIN:-bash watchdog fallback}"
      printf 'docker    : %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf 'UNREACHABLE')"
      # Per service: the container, and whether its classification is the full
      # one or the DEGRADED rule of FR-005a. A container with no POSIX shell
      # cannot host the provenance nonce, so the runner falls back to matching
      # Docker's own error wording — weaker, and the consumer is entitled to
      # know which of its services is in that mode rather than discover it from
      # a warning. The answer is the one probe_shell cached at resolution time;
      # `--doctor` reports it and never probes, so it stays a read-only command.
      printf 'services referenced by the routing table:\n'
      local s cid shellf shellv degraded="" stopped="" running="" cidmap=""
      local svcs; svcs="$(grep -oE '(^|;|\))[[:space:]]*svc[[:space:]]+[a-zA-Z0-9_.-]+' "$0" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
      for s in $svcs; do
        cid="$(lookup_cid "$s")"
        if [[ -z "$cid" ]]; then stopped="$stopped $s"; else running="$running $s"; cidmap="$cidmap$s	$cid
"; fi
        shellf="$(shell_cache "$s")"
        shellv="not probed yet"
        if [[ -f "$shellf" ]]; then
          if [[ "$(cat "$shellf" 2>/dev/null)" == "no" ]]; then
            shellv="NO — DEGRADED classification (FR-005a)"
            degraded="$degraded $s"
          else
            shellv="yes"
          fi
        fi
        printf '  %-20s %-14s shell: %s\n' "$s" "${cid:-NOT RUNNING}" "$shellv"
      done
      [[ -n "$stopped" ]] && printf '  not running:%s — start the stack: make up\n' "$stopped"
      if [[ -n "$degraded" ]]; then
        printf 'degraded  :%s — no POSIX shell, so the runner cannot prove whether the\n' "$degraded"
        printf '            validator ran and matches Docker error wording instead.\n'
      else
        printf 'degraded  : none — every probed service can host the provenance wrapper.\n'
      fi

      # ── Can each running routed service SEE the file it would be given? ────
      #
      # One `docker exec <cid> test -f <path>` per running routed service, over
      # a path derived from the routing table itself: the table is run, for its
      # decision only, over files that really exist in this checkout, and the
      # first file landing on each service is that service's representative.
      # Nothing is asked of the consumer and nothing is invented.
      #
      # A service that cannot see its file validates NOTHING, whatever else
      # above is green. It reports; it never decides whether the hook runs.
      if [[ -n "$running" ]]; then
        printf 'reachability — one `docker exec <svc> test -f <path>` per running service:\n'
        local reps rep_line rep_svc rep_rel rep_given cpath l blind="" unknown="" probed=0
        reps="$(doctor_representatives "$running")"
        for s in $running; do
          rep_line=""
          while IFS= read -r l; do
            [[ -z "$l" ]] && continue
            [[ "${l%%	*}" == "$s" ]] && { rep_line="$l"; break; }
          done <<EOF
$reps
EOF
          if [[ -z "$rep_line" ]]; then
            printf '  %-20s no file in this checkout routes to this service\n' "$s"
            continue
          fi
          rep_svc="${rep_line%%	*}"; rep_rel="${rep_line#*	}"; rep_given="${rep_rel#*	}"; rep_rel="${rep_rel%%	*}"
          cid=""
          while IFS= read -r l; do
            [[ -z "$l" ]] && continue
            [[ "${l%%	*}" == "$s" ]] && { cid="${l#*	}"; break; }
          done <<EOF
$cidmap
EOF
          cpath="$(doctor_container_path "$cid" "${PROJECT_ROOT%/}/$rep_rel" "$rep_given")" || cpath=""
          if [[ -z "$cpath" ]]; then
            printf '  %-20s %s -> ? (the container could not be inspected)\n' "$s" "$rep_rel"
            unknown="$unknown $s"
            continue
          fi
          probed=$(( probed + 1 ))
          doctor_file_visible "$cid" "$cpath"
          case $? in
            0) printf '  %-20s %s -> %s  visible\n' "$s" "$rep_rel" "$cpath" ;;
            1) printf '  %-20s %s -> %s  NOT VISIBLE\n' "$s" "$rep_rel" "$cpath"; blind="$blind $s" ;;
            *) printf '  %-20s %s -> %s  no answer from the container\n' "$s" "$rep_rel" "$cpath"
               unknown="$unknown $s" ;;
          esac
        done
        if [[ -n "$blind" ]]; then
          printf 'blind     :%s — the container is running and cannot see the file the routing\n' "$blind"
          printf '            table would hand it, so that service validates nothing. A wrong\n'
          printf '            `strip`, a mount covering only part of the repository, or a path\n'
          printf '            that never existed in the container.\n'
        elif (( probed > 0 )); then
          printf 'blind     : none — every probed service can see the file routed to it.\n'
        fi
        [[ -n "$unknown" ]] && \
          printf 'undecided :%s — the probe itself did not come back with an answer.\n' "$unknown"
        printf '            The path is where THIS checkout'"'"'s file lives in the container,\n'
        printf '            derived from its mounts: a branch composing the path inside its own\n'
        printf '            `check` line is invisible from here, and is not read back.\n'
      fi

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
# Read before state_init, because it keys the warning sentinels: "once per
# session" is a lie when the key is the project root and the state lives in
# $TMPDIR for days (see warn_once). A host that sends no session id falls back
# to the sentinel's time to live.
_SESSION_ID="$(extract_json_string "$PAYLOAD" "session_id")"
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
  silent "linked worktree, VALIDATE_WORKTREE=skip"
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
