# Case: budget-exhausted-before-the-call
#
# Spec: FR-010 ("When the time budget for an edit is already exhausted at the
# moment a decision is needed, the runner MUST report that the file was not
# validated because the budget ran out"), FR-022 (the message must not assert a
# cause the runner never established) and FR-023 (no temporary file left behind
# on ANY path, "including the path where the budget is exhausted before the
# command starts").
#
# Shape: a live container, a routed check, and a budget of zero seconds. Nothing
# is invoked at all — there is no time to invoke it in.
#
# Three assertions:
#   1. the outcome is a warning, never a violation and never silence;
#   2. the agent is told nothing STARTED, rather than that its tool "was killed",
#      which is a cause the runner did not establish — nothing ran to be killed.
#      This is the red: measured against the runner before this phase, a budget
#      that was already gone produced "`sh` did not finish inside the 0s budget
#      on app.txt and was killed";
#   3. no `validate-out-*` file survives under this case's own TMPDIR.
#
# Assertion 3 is a GUARD, not a win, and the plan was wrong about it. The plan
# says the budget wrapper "creates it and returns 124 without unlinking". The
# wrapper does exactly that — and the caller drains it one frame up
# (`exec_in` -> `drain_budget_out`, which cats and removes), so the file never
# actually survives an edit. Measured on the runner before this phase, on this
# very case: zero strays. The order is inverted here anyway, so that no file is
# created when there is no time to use it, but this case records a leak that was
# never reachable rather than claiming a repair that was never needed.

CASE_DESC="the edit budget is already spent when the validator would start"
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

  VOE_BUDGET_S=0
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'already spent' 'the budget named, and named as already spent' || return 1
  expect_stderr reject 'did not finish' 'a kill the runner never performed' || return 1
  expect_no_stray_temp_files || return 1
  return 0
}
