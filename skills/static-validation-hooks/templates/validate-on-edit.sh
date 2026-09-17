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
#   Cursor  violations -> stdout {"additional_context": ...} + exit 0 (postToolUse)
#   Silent  everything else -> exit 0, no output
#
# Env knobs (all optional):
#   VALIDATE_ON_EDIT=0      Kill-switch. Default 1.
#   VALIDATE_BUDGET_S=3     Hard wall-clock cap per command. Default 3.
#   VALIDATE_MAX_RETRIES=3  Consecutive rejections on one file before muting it.
#   VALIDATE_MUTE_TTL_S=900 How long a muted file stays muted. Default 900.
#   VALIDATE_WORKTREE=auto  auto|skip|run — behaviour inside a linked worktree.
#   VALIDATE_HOST           claude|cursor — force the response shape (else sniffed).
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

# A budget kill is recognised by THIS file's own sentinel, never by exit 124:
# a validator may legitimately choose 124 as its own signal, and claiming that
# code for the runner is the same mistake as claiming 125 for a missing
# container. with_budget runs inside a command substitution, so the sentinel is
# a file the caller can read afterwards, not a variable.
#
# HONEST LIMIT: on the branch that delegates to an external `timeout`, the
# utility's own 124 and a validator's 124 are indistinguishable — timeout
# reports nothing of its own. That ambiguity is pre-existing; the sentinel is
# synthesised there so the outcome stays the safe one (a warning, not a
# violation attributed to the edited file), and it is exact on the watchdog
# branch, where the runner itself did the killing.
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
    "$TIMEOUT_BIN" "$left" "$@" >"$BUDGET_OUT" 2>&1
    local trc=$?
    (( trc == 124 )) && budget_flag_raise
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

# ── Container resolution (cached; the hot path is a single `docker exec`) ─────
compose_project() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then printf '%s' "$COMPOSE_PROJECT_NAME"; return; fi
  basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

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
lookup_candidates() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$(compose_project)" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null
}

# lookup_cid SERVICE — the first candidate, for the diagnostic and for callers
# that only need "is something running". Keeps docker's status.
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

# ── The cause of a failed execution (plan D3) ────────────────────────────────
#
# Four named outcomes, and the fourth is the exhaustive bucket the spec demands
# (FR-006): Docker absent from the PATH and a socket permission refusal land in
# a named cause instead of falling through to a violation.
#
#   daemon         the daemon or the client could not be reached at all
#   nocontainer    no running container for this service
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
# THE EXIT CODE CARRIES NO INFORMATION. Measured on Docker 29.4.0 via OrbStack,
# macOS, 2026-09-17 (specs/016-hook-exit-code-contract/research.md §1):
#
#   container running, validator clean        0
#   container running, validator found 3      3
#   validator absent from the container     127   OCI runtime exec failed: …
#   container stopped                         1   Error response from daemon: …
#   container removed / never existed         1   Error response from daemon: …
#   daemon unreachable                        1   failed to connect to the …
#
# `docker exec` NEVER returns 125, and the three infrastructure failures all
# return 1 — the same code a linter returns when it found something. So the
# runner does not infer: it carries its own evidence. A per-invocation nonce is
# printed INSIDE the container immediately before the validator is handed
# control. Nonce back = the call reached inside and command resolution began;
# no nonce = the validator never started, whatever the code says.
#
# The nonce is NOT a prefix. Docker carries stdout and stderr separately and
# merges them in an order that is not stable across two runs of one unchanged
# command (research.md §2c), so detection looks for it ANYWHERE in the output.
#
# $0 of the wrapper shell is a second per-invocation marker: a shell prefixes
# its own `exec` diagnostic with $0, so `<argv0>: … not found` proves the
# SHELL said it, not the validator. Neither marker is a substring of the other.
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
  docker exec -i "$cid" sh -c 'exit 7' >/dev/null 2>&1; rc=$?
  # Only 7 can come from a real shell, and only 126/127 prove there is none.
  # Any other code (1 = daemon trouble) leaves the question open rather than
  # poisoning the cache with a "no" the next session would inherit.
  case "$rc" in
    7)       printf 'yes' >"$f" 2>/dev/null || true ;;
    126|127) printf 'no'  >"$f" 2>/dev/null || true; log "service '$svc' has no POSIX shell — degraded classification" ;;
  esac
  return 0
}

# exec_in SERVICE CMD... — stdout+stderr merged on stdout, container rc returned.
# 125 is the runner's OWN synthetic code for "no container resolved / docker
# unusable"; `docker exec` cannot produce it. 124 = budget (see _BUDGET_FLAG).
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
# With a shell, the nonce settles it and nothing else is consulted. Without one
# (FR-005a) there is no provenance to read, so the weaker rule of
# classify_degraded is applied here too — Docker's own error wording, with the
# same 126/127 carve-out, so a tool the image does not carry is not mistaken for
# a container that is gone. Deliberately the SAME rule in both places: two
# different weak rules would disagree on the shell-less path.
exec_reached_inside() {
  local svc="$1" rc="$2" out=""
  (( rc == 0 )) && return 0
  [[ -n "$BUDGET_OUT" && -f "$BUDGET_OUT" ]] && out="$(cat "$BUDGET_OUT" 2>/dev/null)"
  if svc_has_shell "$svc"; then
    case "$out" in *"$_NONCE"*) return 0 ;; esac
    return 1
  fi
  is_docker_error "$out" || return 0
  (( rc == 126 || rc == 127 )) && return 0
  return 1
}

# exec_in SERVICE CMD...
#
# Cache invalidation and recovery live HERE, not in the classifier (FR-017). A
# ROUTING TABLE branch that formats before it validates runs `fix` first, and
# `fix` discards its result by design; with the recovery in `check` that branch
# left a dead identifier cached for the validator that follows it.
exec_in() {
  local svc="$1"; shift
  local cache="$STATE_DIR/cid-$svc" cid="" rc=0 cands="" prc=0

  [[ -f "$cache" ]] && cid="$(cat "$cache" 2>/dev/null)"

  # Hot path: one `docker exec` on the cached container id, no lookup at all.
  if [[ -n "$cid" ]]; then
    # A cid cached by an older runner carries no shell answer; probing it here
    # costs one call once, never per edit.
    probe_shell "$svc" "$cid"
    exec_wrapped "$svc" "$cid" "$@"; rc=$?
    budget_was_killed && { drain_budget_out; return "$rc"; }
    exec_reached_inside "$svc" "$rc" && { drain_budget_out; return "$rc"; }

    # Nothing ran. Docker's text is dropped here rather than carried further.
    budget_out_discard
    if (( $(remaining_budget) <= 0 )); then
      # No time for the probe. FR-010: not validated, cause unknown — never a
      # guess, and never a violation.
      log "no budget left to establish why '$svc' did not run"
      cause_set unclassified
      return 125
    fi

    # ONE label-filtered `docker ps`, read as a SET and consumed whole (plan D3).
    cands="$(lookup_candidates "$svc")"; prc=$?
    if (( prc != 0 )); then
      # FR-008: a re-resolution would ask the same unreachable daemon, so it is
      # not attempted. This is the only place that decision is taken.
      log "docker ps failed for '$svc' — daemon unreachable or client refused"
      cause_set daemon
      return 125
    fi
    if [[ -z "${cands//[$'\t\n\r ']/}" ]]; then
      log "no running container for '$svc' — dropping the cached id"
      rm -f "$cache" 2>/dev/null || true
      cause_set nocontainer
      return 125
    fi
    if cands_contain "$cands" "$cid"; then
      log "container $cid for '$svc' is running, yet the call did not reach inside it"
      cause_set unclassified
      return 125
    fi

    # The container was replaced, possibly among several on a scaled service.
    # Take the first candidate and retry exactly once. Verifying the candidate
    # against this checkout is plan D6, Phase D, and is NOT done here.
    cid="${cands%%$'\n'*}"
    printf '%s' "$cid" >"$cache" 2>/dev/null || true
    rm -f "$(shell_cache "$svc")" 2>/dev/null || true
    log "container for '$svc' was replaced — retrying once on $cid"
    probe_shell "$svc" "$cid"
    exec_wrapped "$svc" "$cid" "$@"; rc=$?
    budget_was_killed && { drain_budget_out; return "$rc"; }
    exec_reached_inside "$svc" "$rc" && { drain_budget_out; return "$rc"; }
    budget_out_discard
    log "the replacement container for '$svc' did not run the validator either"
    cause_set unclassified
    return 125
  fi

  cands="$(lookup_candidates "$svc")"; prc=$?
  if (( prc != 0 )); then
    log "docker ps failed for '$svc' — daemon unreachable or client refused"
    cause_set daemon
    return 125
  fi
  cid="${cands%%$'\n'*}"
  [[ -z "$cid" ]] && { log "no running container for '$svc'"; cause_set nocontainer; return 125; }
  printf '%s' "$cid" >"$cache" 2>/dev/null || true
  probe_shell "$svc" "$cid"

  exec_wrapped "$svc" "$cid" "$@"; rc=$?
  budget_was_killed && { drain_budget_out; return "$rc"; }
  exec_reached_inside "$svc" "$rc" && { drain_budget_out; return "$rc"; }
  budget_out_discard
  cause_set unclassified
  return 125
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
#   nonce absent                               infrastructure warning
#   nonce present, rc 0                        silence
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

# Docker's own failure wording. Used ONLY on the shell-less fallback path, where
# no provenance can exist: it is exactly the text-matching rule FR-001 forbids
# as a primary test, which is why nothing else consults it.
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
    nocontainer)
      warn_once "nocontainer-$_SVC" \
        "[validate] service \`$_SVC\` has no running container, so $REL was not validated.
Start the stack (\`make up\`) to re-enable on-edit validation." || true
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
