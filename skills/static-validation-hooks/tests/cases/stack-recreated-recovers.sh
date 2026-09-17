# Case: stack-recreated-recovers
#
# Spec: US1 acceptance 2 and FR-007 — "Given that same removed container, When
# the stack is started again and the agent edits a routed file, Then validation
# runs against the new container without any manual cache clearing."
#
# Shape: start A, edit once so A is cached, remove A, start B carrying the same
# labels, edit again. The second edit must VALIDATE — silence — not warn.
#
# Why silence and not a warning is the sharp assertion here: a runner that warns
# has still protected the agent from a false finding, and would pass the other
# recovery cases, while quietly refusing to validate anything for the rest of
# the session. Recovery is the requirement, not safety.
#
# Discriminating against the runner before this phase: the cached id returns
# rc 1 with a daemon message, no nonce comes back, and the classifier warns
# "no running container" although B is running. Measured red.

CASE_DESC="a container removed and replaced by an identical one"
CASE_EXPECT="silence"

case_body() {
  local first="$PROJECT_NAME-svc-a" second="$PROJECT_NAME-svc-b"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$first" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  # First edit: resolves and caches A. Silence, or nothing was cached.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  voe_container_rm "$first"
  voe_container_start "$second" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
