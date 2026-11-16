# Case: shell-less-container
#
# Spec: FR-005a — "A container that cannot host the provenance evidence MUST
# keep being validated, by a weaker rule that the agent is told about, rather
# than stop being validated at all."
#
# Shape: a live container whose POSIX shell has been deleted (`/bin/sh`,
# `/bin/ash`) while `grep` still works. The nonce wrapper cannot run there at
# all, so the runner must fall back to invoking the validator directly and
# classify by Docker's own error signature — degraded, and said so in the
# warning text.
#
# Two assertions, because "keeps working" has two halves: a clean run must stay
# silent, and a failing run must still reach the agent as a violation.

CASE_DESC="a container with a working validator and no POSIX shell"
CASE_EXPECT="violation"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'REQUIRED_MARKER present\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check grep -q REQUIRED_MARKER "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1
  voe_container_remove_shell "$name" || return 1

  # Half one: the validator still runs, and finds nothing to report.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    clean run in a shell-less container was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # Half two: the same validator, now failing. It exits 1 and prints nothing,
  # which is the status-only shape — a violation naming the code.
  printf 'the marker is gone\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
