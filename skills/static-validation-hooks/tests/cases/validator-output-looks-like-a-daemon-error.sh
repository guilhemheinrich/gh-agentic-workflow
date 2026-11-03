# Case: validator-output-looks-like-a-daemon-error
#
# Spec: US1 acceptance 3, second half, and Edge Cases — "A validator whose own
# output begins with `Error response from daemon:` — a test fixture, or a tool
# linting Docker logs. Classification must not rest on the message text at all."
#
# Guard case, and the adversarial one: it must hold BEFORE and AFTER the fix. A
# fix that classified by matching Docker's error wording would turn this real
# finding into a warning and lose it.
#
# Expected: violation, before and after.

CASE_DESC="a validator whose first output line reads as a Docker daemon error"
CASE_EXPECT="violation"

case_body() {
  local name="$PROJECT_NAME-svc"
  printf 'Error response from daemon: No such container: deadbeef\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      check sh -c 'printf "Error response from daemon: No such container: deadbeef\n"; printf "%s:1: and a real finding after it\n" "$1"; exit 1' _ "/work/$F"
      ;;
  esac
}
RT

  voe_container_start "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
