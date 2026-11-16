# Case: leading-dash-tool-name
#
# Spec: FR-002 — no text produced by the plumbing may reach the agent as a
# finding about the edited file.
#
# Shape: a ROUTING TABLE branch whose tool name begins with `-`. The wrapper
# carries no `--` end-of-options marker, because `--` is fatal on dash
# (measured: `<argv0>: 1: exec: --: not found`, rc 127, on debian and ubuntu),
# so the name is refused at routing time instead — before any container is
# touched — and the agent is told which branch is wrong.
#
# Why this discriminates rather than agreeing with itself. Measured 2026-09-17
# on the wrapper WITHOUT the routing-time refusal:
#
#   alpine:3.20     rc 2    <argv0>: exec: line 0: illegal option -w
#   debian:12-slim  rc 127  <argv0>: 1: exec: -weirdtool: not found
#
# The alpine row is a violation attributed to the edited file, carrying the
# shell's complaint as if it were a finding — the exact defect class this
# feature removes. The debian row is a wiring warning, safe but wrong about the
# cause. One refusal replaces both.
#
# Expected: warning, on every image.

CASE_DESC="a routing branch whose tool name begins with a dash"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check -weirdtool "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
