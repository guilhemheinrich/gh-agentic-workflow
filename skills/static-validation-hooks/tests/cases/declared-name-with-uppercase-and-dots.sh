# Case: declared-name-with-uppercase-and-dots
#
# Spec: US2 acceptance 7 and FR-012 — "Given a declared name carrying uppercase
# letters or dots, When the runner resolves it, Then it matches the label
# Compose actually writes."
#
# The label is not the declared string. Measured 2026-09-17, Compose v5.1.2:
# `name: VOE.Test.Upper` is reported as `voetestupper` — lowercased, and dots
# DROPPED rather than replaced by a separator. A runner passing the declared
# string through verbatim would filter on a label no container carries, which is
# the same silent miss as reading the wrong source.
#
# The expected value here is computed by the same two `tr` steps the runner uses,
# NOT by asking Compose: a fixture that asked Compose would be comparing
# Compose's answer with Compose's answer and would pass whatever the runner did.
# If Compose ever changed that rule, this case fails — which is the point.

CASE_DESC="a declared name carrying uppercase letters and dots"
CASE_EXPECT="silence"

case_body() {
  local declared expected name="$PROJECT_NAME-svc"
  declared="$(printf '%s' "$PROJECT_NAME" | tr '[:lower:]' '[:upper:]').Upper.Case"
  expected="$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  VOE_NO_CPN=1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  printf '    declared %s -> expected label %s\n' "$declared" "$expected" >&2

  cat >"$PROJECT_DIR/compose.yml" <<YML
name: $declared
services:
  app:
    image: $VOE_IMAGE
    command: sleep 900
YML

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$expected" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
