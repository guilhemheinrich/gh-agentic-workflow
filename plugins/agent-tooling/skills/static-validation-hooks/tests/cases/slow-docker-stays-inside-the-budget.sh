# Case: slow-docker-stays-inside-the-budget
#
# Spec: FR-010 and the runner's own headline promise — VALIDATE_BUDGET_S is a
# "hard wall-clock cap per edit". Until this case existed, that cap covered the
# VALIDATOR and nothing else: `docker compose config`, `docker compose ls`,
# `docker ps`, `docker inspect` and the shell probe all ran unbounded, so an
# endpoint that accepted the connection and then stalled made a 3-second hook
# wait for the Docker client's own timeout. On a TCP endpoint that is minutes,
# once per edit, with the agent blocked on every one.
#
# Shape: a cached container that has been removed, so the edit must resolve
# again, and a `docker ps` that takes 20 seconds. The budget is 3.
#
# The assertion is the CLOCK, which is the only instrument that can see this:
# every outcome here is a warning, before the fix and after it, and the two
# differ by seventeen seconds and by which sentence the agent gets. So the case
# asserts the elapsed time of the edit and the cause named — not the class of
# message, which cannot tell them apart.
#
# The delay is injected in front of one subcommand only; everything else reaches
# the real binary untouched.

CASE_DESC="a Docker endpoint that stalls must not outlast the edit's budget"
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

  # First edit, at full speed: resolves and caches the container id.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # The container is gone, so the edit must go and ask — and asking is what
  # stalls. 20s against a 3s budget: no rounding can confuse the two.
  voe_container_rm "$name"
  voe_docker_shim_with "$logf" '
case "$1" in
  ps) sleep 20 ;;
esac' || return 1

  VOE_BUDGET_S=3
  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_elapsed_under 10 || return 1
  expect_stderr want 'did not answer inside' 'the stall named, without claiming the daemon is down' || return 1
  expect_no_stray_temp_files || return 1
  return 0
}
