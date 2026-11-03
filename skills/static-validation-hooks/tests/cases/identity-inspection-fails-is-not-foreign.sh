# Case: identity-inspection-fails-is-not-foreign
#
# Spec: FR-006 — "The third bucket MUST exist and MUST be reported, so an
# unforeseen cause degrades to a warning rather than to a violation", and FR-009,
# which forbids one suppression key from silencing another.
#
# Shape: a running container behind the right labels, and a Docker client whose
# `inspect` fails while its `ps` keeps working. That is what a daemon dying
# between the listing and the inspection looks like from the runner's side, and
# the shim reproduces it exactly: it breaks one subcommand and passes every
# other one to the real binary.
#
# The defect. The checkout-identity test returned a plain "no" when it could not
# read the container's facts, so every candidate was refused for a reason that
# was never established, and the caller reported `foreign` — the agent is told
# "the running container does not read this checkout's copy", a claim about
# mounts nobody looked at. Worse, `foreign` has its own once-per-service
# suppression key: a checkout mismatch that really happens later in the session
# is then silent, because a wrong answer already burned the key.
#
# Expected: a warning, naming the cause as unestablished. Both halves matter,
# and the rejection is the sharper one: the sentence that must NOT appear is the
# one the agent would act on by restarting a stack that is running fine.

CASE_DESC="a listing that succeeds and an inspection that then fails"
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

  # Mounted at /work from THIS project directory: the container would pass the
  # identity test if the test could be run at all, so nothing here is foreign
  # and a `foreign` verdict cannot be excused as accidentally correct.
  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  voe_docker_shim_with "$logf" '
case "$1" in
  inspect) printf "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.\n" >&2; exit 1 ;;
esac' || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1

  # The listing really did work, or the case proves nothing about the pair.
  local ps_calls inspect_calls
  ps_calls="$(voe_docker_calls "$logf" ps)"
  inspect_calls="$(voe_docker_calls "$logf" inspect)"
  printf '    docker calls: ps=%s inspect=%s\n' "$ps_calls" "$inspect_calls" >&2
  voe_assert_tick
  if [ "$ps_calls" = "0" ] || [ "$inspect_calls" = "0" ]; then
    printf '    fixture failed: expected at least one ps and one inspect\n' >&2
    printf '%s' "unexpected:fixture-did-not-reach-inspect" >"$CASE_DIR/observed"
    return 1
  fi

  expect_stderr reject 'does not read this checkout' 'a checkout mismatch nobody established' || return 1
  expect_stderr reject 'has no running container' 'a stopped service blamed for a live one' || return 1
  expect_stderr want 'could not establish why' 'the cause named as unestablished' || return 1
  return 0
}
