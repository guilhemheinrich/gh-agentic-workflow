# Case: validator-exit-1-with-findings
#
# Spec: US1 acceptance 3 — a validator that ran, exited 1 and printed findings
# must deliver them to the agent unchanged.
#
# Guard case: it must hold BEFORE and AFTER the fix. Exit 1 is the exit code
# every real Docker infrastructure failure also returns (research.md §1), so a
# fix that classified every 1 as infrastructure would break exactly this case.
#
# Expected: violation, before and after.

CASE_DESC="a validator that ran, exited 1, and printed findings"
CASE_EXPECT="violation"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'has a problem\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      check sh -c 'printf "%s:1: forbidden token\n" "$1"; exit 1' _ "/work/$F"
      ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
