# Case: container-alive-but-unreachable
#
# Spec: FR-006 — "The runner MUST distinguish the infrastructure causes it can
# act on differently: no running container for the service, a daemon or client
# that cannot be reached or is refused, and ANYTHING ELSE. The third bucket MUST
# exist and MUST be reported, so an unforeseen cause degrades to a warning
# rather than to a violation."
#
# This is the fourth row of the cause table (plan D3): `docker ps` succeeds and
# the candidates INCLUDE the cached id — the container is alive and the call did
# not reach inside it. Nothing else in the suite reaches that row, so without
# this case the exhaustive bucket is implemented and asserted by nothing.
#
# Shape: a paused container. Measured 2026-09-17 on Docker 29.4.0 / OrbStack:
#
#   docker ps -q  -> still lists it        (so it is still a candidate)
#   docker exec   -> rc 1, "Error response from daemon: Container … is paused,
#                    unpause the container before exec"
#
# Nothing is simulated: this is a state a real stack reaches, and it is exactly
# the shape the bucket exists for — Docker answers, the service is running, and
# the validator still did not run.
#
# Expected: a warning. Specifically NOT a violation (the daemon's text must not
# become a finding about the edited file), NOT silence, and NOT "has no running
# container" — the container is right there, and telling the agent to run
# `make up` would be a cause the runner never established.

CASE_DESC="a container that is running and cannot be executed in"
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

  # First edit: resolves and caches the container while it still answers.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  voe_container_pause "$name" || return 1

  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr reject 'has no running container' 'a stopped service blamed for a live one' || return 1
  expect_stderr reject 'Error response from daemon' "Docker's own text reaching the agent" || return 1
  expect_stderr want 'could not establish why' 'the cause named as unestablished' || return 1
  return 0
}
