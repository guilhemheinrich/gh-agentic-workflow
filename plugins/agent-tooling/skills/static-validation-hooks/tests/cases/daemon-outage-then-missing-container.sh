# Case: daemon-outage-then-missing-container
#
# Spec: FR-009 — "Warning suppression scope MUST follow the cause. A daemon or
# client outage warns once for the whole session, since it is not a property of
# any service. A missing container warns once per service. Neither key MUST
# suppress the other, so a daemon outage cannot hide a later genuine
# missing-container warning for a service."
#
# Also the spec's Edge Case: "A daemon that is down while the routing table
# names two services: the agent must not receive the same warning twice, and
# that suppression must not later silence a genuine missing-container warning
# for one of those services."
#
# Shape, three edits against one persistent state directory:
#   1. two services, both running        -> silence, both resolved and cached
#   2. the daemon becomes unreachable    -> ONE warning, naming Docker, for both
#   3. the daemon returns, `voe2` is gone -> a warning naming `voe2`
#
# Step 3 is the assertion this case exists for. A runner keying the daemon
# outage per service — or keying a missing container on a name the daemon
# outage already burned — goes silent there, and the agent never learns that
# `voe2` stopped being validated. Silence is indistinguishable from a clean
# file, which is why this is a suppression bug and not a cosmetic one.

CASE_DESC="a session-wide daemon warning must not silence a later per-service one"
CASE_EXPECT="warning"

case_body() {
  local one="$PROJECT_NAME-svc1" two="$PROJECT_NAME-svc2"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe;  check sh -c 'test -f "$1"' _ "/work/$F"
      svc voe2; check sh -c 'test -f "$1"' _ "/work/$F"
      ;;
  esac
}
RT

  voe_container_start "$one" "$PROJECT_NAME" voe  "$PROJECT_DIR" /work >/dev/null || return 1
  voe_container_start "$two" "$PROJECT_NAME" voe2 "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  VOE_DOCKER_HOST="unix:///tmp/voe-test-$VOE_SESSION-absent.sock"
  printf 'still clean\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "warning" ]; then
    printf '    setup failed: the daemon outage was %s, expected warning\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi
  expect_stderr want 'Docker could not be reached' 'the daemon named once, for both services' || return 1
  expect_stderr reject 'has no running container' 'a service blamed for a daemon outage' || return 1

  # The daemon returns; one of the two services does not.
  VOE_DOCKER_HOST=""
  voe_container_rm "$two"

  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'voe2' 'the service that actually stopped' || return 1
  expect_stderr want 'has no running container' 'the missing container, not the earlier outage' || return 1
  return 0
}
