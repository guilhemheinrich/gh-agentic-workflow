# Case: validator-chooses-127
#
# Spec: FR-003 — "A validator MAY choose 124, 126 or 127 as its own signal;
# those codes MUST NOT be claimed by the runner unless the accompanying
# diagnostic shows the runner itself produced them."
#
# Shape: a validator that ran, printed a finding, and chose 127 as its exit
# code. The old contract swallowed every 127 as "tool not installed", so this
# finding was lost. The only thing that separates it from `tool-absent-from-
# container` is the diagnostic: that one opens with the wrapper shell's own
# argv0, invented per invocation, and this one does not.
#
# Expected: violation carrying the validator's output.

CASE_DESC="a validator choosing 127 as its own signal, with its own output"
CASE_EXPECT="violation"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'has a problem\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      check sh -c 'printf "%s:1: this tool signals with 127\n" "$1"; exit 127' _ "/work/$F"
      ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
