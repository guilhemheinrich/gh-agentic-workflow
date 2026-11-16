# Case: daemon-not-re-resolved
#
# Spec: FR-008 — "On 'daemon unreachable or refused', the runner MUST NOT
# resolve again, because resolution uses the same unreachable daemon."
#
# `daemon-unreachable` asserts the OUTCOME of a dead daemon. It cannot assert
# this requirement: a runner that re-resolved three times would produce exactly
# the same warning, because every attempt fails the same way. The only thing
# that separates "decided once" from "kept asking" is how many times the runner
# called Docker, so that is what this case counts.
#
# Method: a `docker` shim, first on PATH, that appends its subcommand to a log
# and then execs the real binary. Behaviour is unchanged — it counts, it does
# not simulate. This is still outside the runner: the number of processes a
# program starts is as observable as its exit status, and nothing here reads the
# runner's state, its source, or its log.
#
# Shape: resolve a live container first (so the failure lands on the CACHED
# path, where a `docker exec` happens before any lookup), truncate the log,
# point DOCKER_HOST at an absent socket, edit again.
#
# Expected, on the second edit:
#   - exactly ONE `docker ps` — the single label-filtered probe that establishes
#     the cause (plan D3). Two would mean the runner re-resolved after deciding
#     the daemon was gone;
#   - at least one `docker exec` — the cached-path call that failed, without
#     which the count above would be trivially satisfied by doing nothing;
#   - a warning naming Docker rather than a stopped service, so the agent is not
#     sent to run `make up` against a daemon that is down (FR-006).

CASE_DESC="a dead daemon is diagnosed once and not asked again"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc" logf="$CASE_DIR/docker-calls.log"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1
  voe_docker_shim "$logf" || return 1

  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi
  # The shim must actually be in front of the real binary, or every count below
  # would read zero and the case would pass by measuring nothing.
  if [ "$(voe_docker_calls "$logf" exec)" = "0" ]; then
    printf '    fixture failed: the docker shim logged no exec on the first edit\n' >&2
    printf '%s' "unexpected:shim-not-in-path" >"$CASE_DIR/observed"
    return 1
  fi

  : >"$logf"
  # Short on purpose: a unix socket path over ~104 bytes fails as a malformed
  # client argument rather than as an unreachable daemon.
  VOE_DOCKER_HOST="unix:///tmp/voe-test-$VOE_SESSION-absent.sock"

  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1

  local ps_calls exec_calls
  ps_calls="$(voe_docker_calls "$logf" ps)"
  exec_calls="$(voe_docker_calls "$logf" exec)"
  printf '    docker calls on the failing edit: ps=%s exec=%s\n' "$ps_calls" "$exec_calls" >&2
  if [ "$exec_calls" = "0" ]; then
    printf '    expected at least one docker exec on the cached path, got none\n' >&2
    printf '%s' "unexpected:no-exec-attempted" >"$CASE_DIR/observed"
    return 1
  fi
  if [ "$ps_calls" != "1" ]; then
    printf '    expected exactly 1 docker ps after the daemon verdict, got %s\n' "$ps_calls" >&2
    printf '%s' "unexpected:re-resolved-on-dead-daemon" >"$CASE_DIR/observed"
    return 1
  fi

  expect_stderr reject 'has no running container' 'a stopped service blamed for a dead daemon' || return 1
  expect_stderr want 'Docker could not be reached' 'the daemon named as the cause' || return 1
  return 0
}
