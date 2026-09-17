# Case: daemon-unreachable
#
# Spec: US1 acceptance 4 — "Given an unreachable Docker daemon, When the agent
# edits a routed file, Then the hook warns once that validation is unavailable
# and stays silent on later edits."
#
# Shape: point DOCKER_HOST at a unix socket path that does not exist. No
# container is started: the daemon is unreachable for every call the runner
# makes, resolution included.
#
# This case asserts the first edit only. "Stays silent on later edits" is
# warning-suppression behaviour (warn_once), a separate assertion that belongs
# with the cause-scoped keys of FR-009, not here.
#
# Expected after the fix: warning.

CASE_DESC="the Docker daemon cannot be reached"
CASE_EXPECT="warning"

case_body() {
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  # A short, session-unique path that is never created. Short on purpose: a unix
  # socket path longer than ~104 bytes makes the Docker client fail with "socket
  # path is too long" instead of a connection failure, which is a different
  # client error and would test something other than an unreachable daemon.
  VOE_DOCKER_HOST="unix:///tmp/voe-test-$VOE_SESSION-absent.sock"

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
