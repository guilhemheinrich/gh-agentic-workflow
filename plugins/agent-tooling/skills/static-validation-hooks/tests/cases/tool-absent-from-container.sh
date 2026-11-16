# Case: tool-absent-from-container
#
# Spec: FR-003 read from the other side — the runner may claim 126/127 only when
# the diagnostic shows it (or its wrapper shell) produced them. Here it did: the
# routing table names a binary the image does not carry, so the wrapper shell
# refuses to exec it and says so.
#
# Shape: a live container, a routed check on `definitely-not-a-linter`.
# Measured on alpine 3.20, 2026-09-17: the shell answers
# `<argv0>: exec: line 0: definitely-not-a-linter: not found`, rc 127.
#
# Expected: warning (wiring) — never a violation about the edited file, and
# never silence.

CASE_DESC="a tool the container does not carry"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check definitely-not-a-linter --check "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
