# Case: shell-less-unknown-docker-wording
#
# Spec: FR-001 ("Classification MUST rest on that evidence, not on the exit code
# and not on the wording of an error message") and FR-002 ("no text produced by
# Docker itself MUST reach the agent as a finding"), on the ONE path where no
# provenance can exist: a container with no POSIX shell (FR-005a).
#
# Shape: a shell-less container, resolved and cached by a first clean edit, then
# a Docker client that cannot initialise at all — a unix socket path longer than
# the 104 bytes the platform allows.
#
# Measured 2026-09-17, Docker 29.4.0 via OrbStack, both `ps` and `exec`:
#
#   Failed to initialize: unix socket path "/tmp/aaa…/docker.sock" is too long
#
# That sentence matches none of the signatures the runner knows, and on the
# shell-less path the absence of a match USED to mean "the validator spoke".
# So Docker's own line arrived as a finding about app.txt, attributed to `grep`
# and to an exit code grep never returned — the original defect, walked back in
# through the degraded door. An older client's `error during connect …` is the
# same shape; one measured wording is enough to pin the rule.
#
# The fix is not a longer list of signatures — that list can only ever be as
# current as the Docker release it was written against. It is to ask Docker what
# STATE the service is in before reading any text, which is the probe the
# shell-ful path already runs, and to leave the wording as a last resort for the
# one question the state cannot answer.
#
# Expected: a warning. The specific cause is Docker's unreachability, so the
# daemon sentence is the one the agent must get — not a missing container, and
# above all not a finding.

CASE_DESC="a shell-less container and a Docker failure whose wording is unknown"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc" long=""

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

  # First edit: resolves the container, records that it has no shell, validates.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # 120 bytes of path plus the socket name: over the platform's limit, so the
  # client fails before it connects and says so in words no signature carries.
  long="$(awk 'BEGIN { s = ""; while (length(s) < 120) s = s "a"; print s }')"
  VOE_DOCKER_HOST="unix:///tmp/voe-test-$VOE_SESSION-$long/docker.sock"

  # The fixture must really produce the unknown wording, or this case is
  # asserting against a failure it did not create.
  local seen
  seen="$(DOCKER_HOST="$VOE_DOCKER_HOST" docker ps -q 2>&1)"
  case "$seen" in
    *"is too long"*) ;;
    *)
      printf '    fixture failed: the client said %s\n' "$seen" >&2
      printf '%s' "unexpected:wording-not-reproduced" >"$CASE_DIR/observed"
      return 1
      ;;
  esac

  printf 'REQUIRED_MARKER still present\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr reject 'is too long' "Docker's own text reaching the agent" || return 1
  expect_stderr want 'Docker could not be reached' 'the outage named as the cause' || return 1
  expect_no_stray_temp_files || return 1
  return 0
}
