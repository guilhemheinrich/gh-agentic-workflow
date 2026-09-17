# Case: daemon-unreachable
#
# Spec: US1 acceptance 4 — "Given an unreachable Docker daemon, When the agent
# edits a routed file, Then the hook warns once that validation is unavailable
# and stays silent on later edits."
#
# Shape: resolve a real container FIRST, so the second edit runs on the CACHED
# path, and only then point DOCKER_HOST at a unix socket that does not exist.
#
# Why the cached path, and not simply a dead daemon from the start: with no
# cached id the failure is taken by `lookup_cid`, whose empty output the runner
# reads as "no container" and answers with its own synthetic 125 — an
# accidentally safe warning that never touches the defect. On the cached path
# the dead daemon reaches `docker exec`, which returns 1 with a daemon message,
# and that is where a violation about the edited file is produced today.
# BASELINE.md note 1 recorded exactly this shape as unmeasured by the suite.
#
# This case asserts the second edit only. "Stays silent on later edits" is
# warning-suppression behaviour (warn_once), a separate assertion that belongs
# with the cause-scoped keys of FR-009, not here.
#
# Expected after the fix: warning.

CASE_DESC="the Docker daemon becomes unreachable with a container already cached"
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

  # First edit against a live daemon: resolves and caches the container id.
  # Must be silent, otherwise nothing was cached and the second edit would be
  # the uncached path this case exists to avoid.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # A short, session-unique path that is never created. Short on purpose: a unix
  # socket path longer than ~104 bytes makes the Docker client fail with "socket
  # path is too long" instead of a connection failure, which is a different
  # client error and would test something other than an unreachable daemon.
  VOE_DOCKER_HOST="unix:///tmp/voe-test-$VOE_SESSION-absent.sock"

  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
