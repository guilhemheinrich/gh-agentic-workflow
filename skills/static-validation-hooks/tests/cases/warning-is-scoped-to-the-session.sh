# Case: warning-is-scoped-to-the-session
#
# Spec: FR-009 — "A daemon or client outage warns once for the whole SESSION,
# since it is not a property of any service."
#
# Shape: the same daemon outage met by two different sessions, told apart the
# way the hosts tell them apart — by the `session_id` their event carries. Both
# must warn.
#
# The defect: the sentinel was keyed on the project root alone and lives in
# $TMPDIR, so "once per session" meant once for the lifetime of a temporary
# directory — days, across reboots of the daemon and restarts of the agent. The
# second session's warning was suppressed and its hook exited in silence, which
# is the one outcome an agent cannot distinguish from a clean file. The sequence
# that bites is ordinary: an outage on Monday, Docker recovers, another outage
# on Wednesday, and the agent is never told.
#
# The suppression it must NOT break is the one the same session asks for, so
# this case asserts both halves: the second session warns, and a repeat inside
# THAT session does not.

CASE_DESC="a second session must be warned about an outage the first one saw"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  # Session A, live daemon: resolves and caches, silently.
  VOE_SESSION_ID="voe-session-A-$CASE_INDEX"
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # Session A meets the outage and is told about it.
  VOE_DOCKER_HOST="unix:///tmp/voe-test-$VOE_SESSION-absent.sock"
  printf 'still clean\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "warning" ]; then
    printf '    setup failed: session A was %s on the outage, expected warning\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # Still session A: the same outage, and the agent is not told twice.
  printf 'and again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  voe_assert_tick
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    session A was told twice about one outage (%s)\n' "$RUN_OUTCOME" >&2
    printf '%s' "unexpected:warned-twice-in-one-session" >"$CASE_DIR/observed"
    return 1
  fi

  # A different session, same machine, same project, same outage.
  VOE_SESSION_ID="voe-session-B-$CASE_INDEX"
  printf 'a new session edits\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'Docker could not be reached' 'the outage named to the second session' || return 1
  return 0
}
