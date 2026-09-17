# Case: validator-killed-by-the-budget
#
# Spec: FR-010 and FR-022 — a validator that outruns the edit's budget is
# stopped, the agent is told the file was not validated, and the message does
# not assert a cause the runner never established.
#
# Shape: a live container and a routed check that sleeps far past a 2s budget.
#
# This is the twin of `validator-chooses-124`, and neither is worth much
# alone. Telling a kill from a validator's own 124 is a discrimination, so it
# can be broken in two directions, and a suite carrying only one of the pair
# would call a runner correct for guessing the same answer every time:
#
#   only the 124 case      a runner that never raises the budget sentinel is
#                          green, and every genuinely killed validator becomes
#                          a violation carrying half its own output
#   only this case         a runner that always raises it is green, which is
#                          the defect this pair exists to catch
#
# Both run on both images, so the discrimination is proved for ash and for dash.

CASE_DESC="a validator that outruns the edit's budget and is stopped"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'sleep 30' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  VOE_BUDGET_S=2
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'did not finish inside' 'the budget named as the cause' || return 1
  # FR-022: the runner does not know WHY it was slow, and must not say.
  expect_stderr want 'does not know why' 'the cause left unclaimed' || return 1
  # The edit must actually stop at the budget, not at the sleep.
  expect_elapsed_under 10 || return 1
  expect_no_stray_temp_files || return 1
  return 0
}
