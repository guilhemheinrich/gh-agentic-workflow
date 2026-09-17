# Case: status-only-check
#
# Spec: US1 acceptance 6 — "Given a routing-table check that communicates only
# through its exit code, such as a silent pattern search, When it fails on the
# edited file, Then the agent receives a violation naming the exit code, not a
# warning and not silence."
#
# Shape: `grep -q` inside the container, on a file that does not contain the
# pattern. It ran, it exited 1, it printed nothing.
#
# Expected after the fix: violation.

CASE_DESC="a check that speaks only through its exit code"
CASE_EXPECT="violation"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'this file does not carry the required marker\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check grep -q REQUIRED_MARKER "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
