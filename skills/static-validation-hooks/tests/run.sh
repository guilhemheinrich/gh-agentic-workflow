#!/usr/bin/env bash
# skills/static-validation-hooks/tests/run.sh
#
# Black-box driver for templates/validate-on-edit.sh.
#
# Each case: copy the runner to a temp directory, substitute a case-specific
# routing table between the BEGIN/END ROUTING TABLE markers, invoke the copy the
# way a hook invokes it (JSON payload on stdin, not a tty), capture the exit
# status and stderr, and assert the agent-visible outcome.
#
# ── The observability mapping, derived from the runner ───────────────────────
#
# Line numbers are against templates/validate-on-edit.sh at 7ffd01d, the
# unmodified runner this suite was written against.
#
# The runner has exactly one agent-facing exit, `emit_feedback` (:151-159). With
# VALIDATE_HOST=claude it writes the message to stderr and exits 2 (:153-156);
# with cursor it writes JSON to stdout and exits 0 (:157-158). Everything else
# exits 0 with nothing on stderr (`silent` :55, the tail :598-600).
#
# The suite drives the claude shape, because it is the one that separates
# "something to say" from "nothing to say" through the exit status alone.
#
#   silence    exit 0, stderr empty
#              — no violation and no warning reached emit_feedback (:598-600)
#
#   violation  exit 2, first stderr line: "[validate] <path> — <tool> (exit N)"
#              — the only place that shape is produced is :343-345, the
#                assignment of _VIOLATION, emitted at :595
#
#   warning    exit 2, first stderr line starts "[validate] " but is NOT the
#              violation shape
#              — every warn_once message (:324, :331, :337, :478) opens that way
#                and none of them carries "— <tool> (exit N)"; WARNING is
#                emitted at :599
#
# HONEST LIMITATION, and a finding about the runner rather than about the suite:
# a violation and a warning are NOT distinguishable by exit status. Both are
# exit 2 with text on stderr, because emit_feedback is shared (:151-159). The
# only outside discriminator is the shape of the first line. So the suite reads
# the text — but it reads it as an ATTRIBUTION marker ("this file, this tool,
# this exit code"), never as a classification: it does not know, and must never
# know, which exit codes or which messages the runner considers infrastructure.
# That is the whole point of plan D8. `--check` (:502-512) does separate the two
# by exit status (1 vs 0), but that is a human CLI path, not the path an agent
# sees, so the suite does not assert against it.
#
# Anything else — a non-zero exit that is not 2, stderr on an exit 0, an exit 2
# whose first line is not the runner's own prefix — is reported as
# `unexpected:<detail>` and fails the case. The suite never guesses.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   bash run.sh                 run every case, stop at the first failure
#   bash run.sh --all           run every case, report all failures
#   bash run.sh --case NAME     run one case
#   bash run.sh --image IMG     run the matrix on this image only
#   bash run.sh --list          list case names
# Exits non-zero if any case failed.
#
# ── The image matrix, and why there is one ───────────────────────────────────
#
# Every case runs once per image in $VOE_IMAGES (default: alpine:3.20 and
# debian:12-slim). The runner injects a `sh -c` wrapper into every validator
# call, so the SHELL inside the container is part of the contract, and the two
# shells that matter behave differently: alpine is busybox ash, Debian and
# Ubuntu are dash. An earlier wrapper passed `--` before the tool; measured
# 2026-09-17, that is rc 0 on ash and rc 127 on dash, which the classifier would
# have read as "tool not installed" — one warning per service, then permanent
# silence on every Debian-based stack.
#
# A single-image fixture set could not see that, and did not: the suite was
# green while exercising one of the two shells it claimed to cover. That is the
# same failure shape as the defect this feature exists to remove, so the matrix
# is part of the suite rather than a nicety.
#
# ── One case has a different shape: the mutation case ────────────────────────
#
# `mutation-provenance-becomes-infrastructure` asserts nothing about a hook run
# of its own. It copies the runner, deletes ONE named line — the provenance test
# in `exec_reached_inside` — and re-enters this script through $VOE_RUNNER to
# replay two guard cases against the copy, requiring both to fail. It is the
# only case that calls run.sh recursively, and the only one that writes
# $CASE_DIR/observed itself instead of going through `expect_outcome`, because
# its verdict is about the SUITE rather than about the runner's output.
#
# Its recursion is bounded by construction: it passes --case, never --all, and
# sets VOE_MUTATION_DEPTH so a nested invocation of itself refuses.
#
# Requirements: Docker, and the images in $VOE_IMAGES. No project stack.
# bash 3.2 compatible.

set -o pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RUNNER_SRC="${VOE_RUNNER:-$SKILL_DIR/templates/validate-on-edit.sh}"

[ -f "$RUNNER_SRC" ] || { printf 'run.sh: runner not found: %s\n' "$RUNNER_SRC" >&2; exit 1; }

VOE_SESSION="$$"
VOE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/voe-test-$VOE_SESSION-XXXXXX")" || exit 1
VOE_REGISTRY="$VOE_ROOT/containers.registry"
: >"$VOE_REGISTRY"
export VOE_REGISTRY
VOE_VOLUMES="$VOE_ROOT/volumes.registry"
: >"$VOE_VOLUMES"
export VOE_VOLUMES

# How many assertions this run actually evaluated. A case body runs in a
# subshell, so the counter is a file: one byte per assertion, counted at the
# end. It exists so the run can REPORT a measured number instead of a number
# read off the source, where a helper call inside an untaken branch would be
# counted and a case that returned early would not.
#
# A nested run (the mutation case) resets this to its own sandbox, so its
# replays are counted there and never folded into the parent's total.
VOE_ASSERTS="$VOE_ROOT/asserts.count"
: >"$VOE_ASSERTS"
export VOE_ASSERTS

# voe_assert_tick — record that one assertion was evaluated.
voe_assert_tick() { printf 'x' >>"$VOE_ASSERTS" 2>/dev/null || true; return 0; }

. "$TESTS_DIR/fixtures/container.sh"
. "$TESTS_DIR/fixtures/worktree.sh"

# The image matrix. Every case runs once per image: the container-side shell is
# part of the contract (see the header), and alpine is ash while debian is dash.
VOE_IMAGES="${VOE_IMAGES:-alpine:3.20 debian:12-slim}"

VOE_KEEP="${VOE_KEEP:-0}"

cleanup() {
  voe_teardown_all
  if [ "$VOE_KEEP" = "1" ]; then
    printf 'run.sh: sandbox kept at %s\n' "$VOE_ROOT" >&2
  else
    rm -rf "$VOE_ROOT" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

CASES="stale-container-reported-as-violation
daemon-unreachable
validator-exit-1-with-findings
validator-output-looks-like-a-daemon-error
status-only-check
tool-absent-from-container
leading-dash-tool-name
validator-chooses-127
shell-less-container
stack-recreated-recovers
scaled-service-two-containers
format-then-validate-shares-recovery
daemon-not-re-resolved
daemon-outage-then-missing-container
budget-exhausted-before-the-call
container-alive-but-unreachable
compose-file-declares-the-name
dotenv-declares-the-name
declared-name-with-uppercase-and-dots
nested-name-serialised-first
volume-shadows-the-checkout
worktree-shares-the-main-stack
worktree-sharing-opt-out
resolver-override-keeps-validating
mutation-provenance-becomes-infrastructure"

# ── Harness primitives available to every case ───────────────────────────────

# install_runner <routing-table-file>
# Copies the runner, replacing everything strictly between the BEGIN and END
# ROUTING TABLE marker lines with the case's routing table. Sets RUNNER_COPY.
# Fails loudly unless exactly one BEGIN and one END marker matched: a silent
# substitution miss would leave the factory table in place and every case would
# pass by validating nothing.
install_runner() {
  local rt="$1" begin end
  # Count the marker lines the substitution actually keys on, not every mention
  # of the words: the banner text above the table names them too.
  begin="$(grep -c '^# BEGIN ROUTING TABLE' "$RUNNER_SRC")"
  end="$(grep -c 'END ROUTING TABLE ═' "$RUNNER_SRC")"
  if [ "$begin" != "1" ] || [ "$end" != "1" ]; then
    printf 'harness: expected exactly one BEGIN and one END marker, got %s/%s\n' \
      "$begin" "$end" >&2
    return 1
  fi

  RUNNER_COPY="$CASE_DIR/validate-on-edit.sh"
  awk -v rtfile="$rt" '
    /^# BEGIN ROUTING TABLE/ {
      print
      while ((getline line < rtfile) > 0) print line
      close(rtfile)
      skipping = 1
      next
    }
    /END ROUTING TABLE ═/ { skipping = 0 }
    !skipping { print }
  ' "$RUNNER_SRC" >"$RUNNER_COPY" || return 1
  chmod +x "$RUNNER_COPY"

  # The copy must still parse, and must still carry both markers.
  bash -n "$RUNNER_COPY" || { printf 'harness: routing table broke the copy\n' >&2; return 1; }
  return 0
}

# write_routing_table — reads the routing table from stdin.
write_routing_table() {
  cat >"$CASE_DIR/routing-table.sh"
  install_runner "$CASE_DIR/routing-table.sh"
}

# run_hook <absolute-file-path>
# Invokes the runner copy the way a PostToolUse hook does: the JSON payload on
# stdin, cwd at the project root, stdin not a tty. Sets RUN_RC, RUN_STDERR,
# RUN_STDOUT and RUN_OUTCOME.
run_hook() {
  local file="$1" payload=""
  RUN_N=$(( ${RUN_N:-0} + 1 ))
  local errf="$CASE_DIR/stderr.$RUN_N" outf="$CASE_DIR/stdout.$RUN_N"

  payload="{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\","
  payload="$payload\"tool_input\":{\"file_path\":\"$file\"},\"tool_response\":{}}"

  # Every case but one pins the project through the exported variable, which is
  # the highest of Compose's four sources and therefore the one that proves
  # nothing about the other three. A case that must exercise the Compose file,
  # the project `.env` or the basename sets VOE_NO_CPN=1 and the variable is not
  # passed at all. `env -u` first, so a developer's own exported value in the
  # calling shell cannot leak into those cases and make them pass for free.
  local cpn="COMPOSE_PROJECT_NAME=$PROJECT_NAME"
  [ "${VOE_NO_CPN:-0}" = "1" ] && cpn="VOE_CPN_NOT_EXPORTED=1"

  (
    cd "$PROJECT_DIR" || exit 90
    printf '%s' "$payload" | env \
      -u COMPOSE_PROJECT_NAME -u COMPOSE_FILE -u COMPOSE_PROFILES -u COMPOSE_ENV_FILES \
      TMPDIR="$CASE_TMPDIR" \
      VALIDATE_HOST=claude \
      VALIDATE_ON_EDIT=1 \
      VALIDATE_BUDGET_S="${VOE_BUDGET_S:-10}" \
      VALIDATE_DEBUG=0 \
      VALIDATE_WORKTREE="${VOE_WORKTREE:-auto}" \
      "$cpn" \
      PATH="${VOE_PATH_PREFIX:+$VOE_PATH_PREFIX:}$PATH" \
      VOE_DOCKER_LOG="${VOE_DOCKER_LOG:-}" \
      ${VOE_DOCKER_HOST:+DOCKER_HOST="$VOE_DOCKER_HOST"} \
      bash "$RUNNER_COPY"
  ) >"$outf" 2>"$errf"
  RUN_RC=$?
  RUN_STDERR="$(cat "$errf")"
  RUN_STDOUT="$(cat "$outf")"
  RUN_OUTCOME="$(classify_outcome "$RUN_RC" "$errf" "$outf")"
  printf '    run %s: rc=%s outcome=%s\n' "$RUN_N" "$RUN_RC" "$RUN_OUTCOME" >&2
  return 0
}

# classify_outcome RC STDERR_FILE STDOUT_FILE — the mapping documented above.
# Reads ONLY the exit status and the first line of stderr. It knows nothing
# about docker, exit-code arms, or which failures are infrastructure.
classify_outcome() {
  local rc="$1" errf="$2" outf="$3" first=""
  first="$(head -n1 "$errf" 2>/dev/null)"

  if [ "$rc" -eq 0 ]; then
    if [ -s "$errf" ]; then printf 'unexpected:exit-0-with-stderr'; else printf 'silence'; fi
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    if printf '%s' "$first" | grep -Eq '^\[validate\] .+ — .+ \(exit [0-9]+\)$'; then
      printf 'violation'
    elif printf '%s' "$first" | grep -q '^\[validate\] '; then
      printf 'warning'
    else
      printf 'unexpected:exit-2-unrecognised-first-line'
    fi
    return 0
  fi
  printf 'unexpected:exit-%s' "$rc"
}

# expect_outcome <expected> — assert the outcome of the last run_hook.
expect_outcome() {
  local want="$1"
  voe_assert_tick
  if [ "$RUN_OUTCOME" = "$want" ]; then
    CASE_VERDICT="PASS"
  else
    CASE_VERDICT="FAIL"
    printf '    expected %s, observed %s\n' "$want" "$RUN_OUTCOME" >&2
  fi
  printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
  printf '%s' "$RUN_RC" >"$CASE_DIR/observed.rc"
  cp "$CASE_DIR/stderr.$RUN_N" "$CASE_DIR/observed.stderr" 2>/dev/null || true
  [ "$CASE_VERDICT" = "PASS" ]
}

# expect_stderr <want|reject> <extended regex> [label]
#
# Asserts what the agent is TOLD, on top of what class of message it got.
#
# This is not a back door into classification, and the distinction matters
# enough to write down. `classify_outcome` decides violation / warning / silence
# and must stay ignorant of Docker; this helper is used only where the
# SPECIFICATION requires a particular cause to be named to the agent — FR-006
# ("the runner MUST distinguish the infrastructure causes") and FR-009 (one key
# must not suppress another). Without it a case can only see that *some*
# warning arrived, and every cause-distinguishing requirement in the spec would
# be asserted by nothing. It still never decides which causes are infrastructure:
# each case names the sentence it expects, and the suite just looks for it.
expect_stderr() {
  local mode="$1" re="$2" label="${3:-$2}" hit=0
  voe_assert_tick
  printf '%s' "$RUN_STDERR" | grep -Eq "$re" && hit=1
  if { [ "$mode" = "want" ] && [ "$hit" = "1" ]; } ||
     { [ "$mode" = "reject" ] && [ "$hit" = "0" ]; }; then
    return 0
  fi
  CASE_VERDICT="FAIL"
  printf '    stderr %s %s — not satisfied. stderr was:\n' "$mode" "$label" >&2
  printf '%s\n' "$RUN_STDERR" | sed 's/^/      | /' >&2
  printf '%s' "unexpected:stderr-$mode-failed" >"$CASE_DIR/observed"
  return 1
}

# expect_no_stray_temp_files — FR-023. The runner's budget wrapper writes its
# temporary output under $TMPDIR, which is this case's own directory, so a file
# it failed to unlink is visible from outside without knowing anything about the
# runner's internals.
expect_no_stray_temp_files() {
  local strays
  voe_assert_tick
  strays="$(ls "$CASE_TMPDIR"/validate-out-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$strays" = "0" ] && return 0
  CASE_VERDICT="FAIL"
  printf '    %s temporary output file(s) left behind in %s:\n' "$strays" "$CASE_TMPDIR" >&2
  ls -l "$CASE_TMPDIR"/validate-out-* 2>/dev/null | sed 's/^/      | /' >&2
  printf '%s' "unexpected:stray-temp-file" >"$CASE_DIR/observed"
  return 1
}

# voe_docker_shim <log-file>
# Writes a `docker` shim into this case's own directory and points
# VOE_PATH_PREFIX and VOE_DOCKER_LOG at it, so the next run_hook counts every
# Docker invocation the runner makes. The shim logs the subcommand and then
# execs the real binary, so behaviour is unchanged — it only counts.
voe_docker_shim() {
  local logf="$1" dir="$CASE_DIR/shim"
  mkdir -p "$dir" || return 1
  : >"$logf"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "$VOE_DOCKER_LOG" 2>/dev/null\n'
    printf 'exec %s "$@"\n' "$VOE_DOCKER_BIN"
  } >"$dir/docker" || return 1
  chmod +x "$dir/docker" || return 1
  VOE_PATH_PREFIX="$dir"
  VOE_DOCKER_LOG="$logf"
  return 0
}

# voe_docker_calls <log-file> <subcommand> — how many times the runner invoked
# `docker <subcommand>` since the log was last truncated.
voe_docker_calls() {
  # BSD grep has no reliable \b, so the separator is the literal space the shim
  # writes between the subcommand and its flags.
  grep -c "^$2 " "$1" 2>/dev/null | tr -d ' \n'
}

# ── Case execution ───────────────────────────────────────────────────────────

run_one_case() {
  local name="$1" file="$TESTS_DIR/cases/$1.sh" rc=0

  [ -f "$file" ] || { printf 'run.sh: no such case: %s\n' "$name" >&2; return 1; }

  CASE_DIR="$VOE_ROOT/$IMAGE_KEY/$name"
  CASE_TMPDIR="$CASE_DIR/tmp"
  PROJECT_NAME="voe-test-$VOE_SESSION-$CASE_INDEX"
  PROJECT_DIR="$CASE_DIR/$PROJECT_NAME"
  mkdir -p "$CASE_TMPDIR" "$PROJECT_DIR" || return 1
  # find_project_root (:388-398) stops at a Makefile when git says nothing.
  : >"$PROJECT_DIR/Makefile"
  RUN_N=0
  VOE_DOCKER_HOST=""
  VOE_PATH_PREFIX=""
  VOE_DOCKER_LOG=""
  VOE_BUDGET_S=""
  VOE_NO_CPN=0
  VOE_WORKTREE=""
  CASE_VERDICT="FAIL"

  printf '  %-44s [%s]\n' "$name" "$VOE_IMAGE" >&2
  # The case body runs in a subshell so a case cannot leak env (DOCKER_HOST,
  # exports) into the next one.
  (
    CASE_EXPECT=""
    CASE_DESC=""
    . "$file" || exit 91
    case_body
  )
  rc=$?

  local observed="unexpected:case-did-not-report"
  [ -f "$CASE_DIR/observed" ] && observed="$(cat "$CASE_DIR/observed")"
  printf '%s\t%s\t%s\t%s\n' "$VOE_IMAGE" "$name" "$rc" "$observed" >>"$VOE_ROOT/results.tsv"
  return $rc
}

# ── Main ─────────────────────────────────────────────────────────────────────

MODE="first-failure"
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all)  MODE="all" ;;
    --case) shift; ONLY="$1" ;;
    --image) shift; VOE_IMAGES="$1" ;;
    --list) printf '%s\n' "$CASES"; exit 0 ;;
    -h|--help) sed -n '1,60p' "$0"; exit 0 ;;
    *) printf 'run.sh: unknown flag: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || { printf 'run.sh: docker not on PATH\n' >&2; exit 1; }
# Resolved once, and only so a case that counts Docker invocations can put a
# logging shim in front of the real binary without hard-coding its location.
VOE_DOCKER_BIN="$(command -v docker)"
for img in $VOE_IMAGES; do
  docker image inspect "$img" >/dev/null 2>&1 || {
    printf 'run.sh: pulling %s\n' "$img" >&2
    docker pull "$img" >/dev/null 2>&1 || { printf 'run.sh: cannot pull %s\n' "$img" >&2; exit 1; }
  }
done

: >"$VOE_ROOT/results.tsv"
FAILED=0
PASSED=0
CASE_INDEX=0
START="$(date +%s)"

printf 'runner  : %s\n' "$RUNNER_SRC" >&2
printf 'images  : %s\n' "$VOE_IMAGES" >&2
printf 'sandbox : %s\n' "$VOE_ROOT" >&2

# --case also accepts a case file that is not in the list above, so a maintainer
# can drop a throwaway probe into cases/ and run it without editing this file.
if [ -n "$ONLY" ]; then
  case "
$CASES
" in *"
$ONLY
"*) ;; *) CASES="$ONLY" ;; esac
fi

# Every case, on every image. The shell inside the container is part of the
# contract the runner asserts, so one image proves the contract for one shell
# and nothing more.
for img in $VOE_IMAGES; do
  VOE_IMAGE="$img"
  IMAGE_KEY="$(printf '%s' "$img" | tr -c 'A-Za-z0-9._-' '-')"
  printf '\n%s\n' "$img" >&2
  for c in $CASES; do
    CASE_INDEX=$(( CASE_INDEX + 1 ))
    if [ -n "$ONLY" ] && [ "$ONLY" != "$c" ]; then continue; fi
    if run_one_case "$c"; then
      PASSED=$(( PASSED + 1 ))
      printf '    PASS\n' >&2
    else
      FAILED=$(( FAILED + 1 ))
      printf '    FAIL\n' >&2
      [ "$MODE" = "first-failure" ] && break 2
    fi
  done
done

if [ -n "$ONLY" ] && [ $(( PASSED + FAILED )) -eq 0 ]; then
  printf 'run.sh: no such case: %s\n' "$ONLY" >&2
  exit 64
fi

printf '\n%s passed, %s failed, %s assertions, %ss elapsed\n' \
  "$PASSED" "$FAILED" "$(wc -c <"$VOE_ASSERTS" | tr -d ' ')" \
  "$(( $(date +%s) - START ))" >&2
[ "$FAILED" -eq 0 ]
