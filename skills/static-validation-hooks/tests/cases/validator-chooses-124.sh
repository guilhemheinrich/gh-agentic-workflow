# Case: validator-chooses-124
#
# Spec: FR-003 — "A validator MAY choose 124, 126 or 127 as its own signal;
# those codes MUST NOT be claimed by the runner unless the accompanying
# diagnostic shows the runner itself produced them." And the promise the whole
# feature rests on: a finding must never be lost.
#
# Shape: a live container, a routed check that prints a finding and exits 124,
# and a budget far larger than the time it takes. Nothing is killed by anybody.
#
# Why it was lost. An external `timeout` returns 124 both when it killed its
# child and when the child chose 124 for itself, and the runner raised its
# budget sentinel from that status alone. The budget arm of `check` runs before
# provenance is consulted, so the agent was told its tool "was killed" and the
# finding was discarded — on every machine carrying GNU coreutils, which is
# every Linux one and any Mac with homebrew's coreutils on the PATH.
#
# The twin of this case is `validator-killed-by-the-budget`: one of the two must
# be a violation and the other a warning, and a runner that cannot tell them
# apart fails one of the pair whichever way it guesses.

CASE_DESC="a validator that prints a finding and exits 124 on its own"
CASE_EXPECT="violation"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'has a problem\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      check sh -c 'printf "%s:1: this tool signals with 124\n" "$1"; exit 124' _ "/work/$F"
      ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  VOE_BUDGET_S=10
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'this tool signals with 124' 'the finding itself' || return 1
  expect_stderr reject 'was killed' 'a kill the runner never performed' || return 1
  expect_no_stray_temp_files || return 1
  return 0
}
