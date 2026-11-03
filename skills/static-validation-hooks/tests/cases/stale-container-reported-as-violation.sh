# Case: stale-container-reported-as-violation
#
# Spec: US1 acceptance 1 — "Given a cached container that has since been
# removed, When the agent edits a routed file, Then the hook reports that the
# file was not validated, and no text from the Docker daemon reaches the agent
# as a finding."
#
# Shape: start a container, edit once so the runner resolves and caches its id,
# remove the container, edit again. The second edit is the assertion.
#
# Expected after the fix: warning.

CASE_DESC="a cached container that no longer exists"
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

  # First edit: resolves and caches the container id. Must be silent, otherwise
  # the cache was never populated and the second edit proves nothing.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi
  voe_container_rm "$name"

  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
