# Case: compose-file-declares-the-name
#
# Spec: US2 acceptance 1 — "Given a Compose file declaring `name:` and no
# exported variable, When the runner resolves the project, Then it resolves the
# declared name."
#
# This is the second defect of the feature, in its original shape: measured in
# `modelo-broker-pa`, whose `compose.yml` declares `name: broker-pa` while the
# checkout directory is `modelo-broker-pa`. The runner read two of Compose's
# four sources, matched no container, warned once, and went silent for the rest
# of the session — a permanent, invisible loss of validation.
#
# Shape: no COMPOSE_PROJECT_NAME at all (VOE_NO_CPN=1), a compose.yml declaring
# a name that is NOT the directory basename, and a container carrying the
# declared name. The edit must validate.
#
# Discriminating against the runner before this phase: the basename rule
# resolves the directory name, no container carries it, and the outcome is a
# warning. Silence is only reachable by reading the Compose file.

CASE_DESC="a stack named in the Compose file, with nothing exported"
CASE_EXPECT="silence"

case_body() {
  local declared="$PROJECT_NAME-declared" name="$PROJECT_NAME-svc"
  VOE_NO_CPN=1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

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

  # The container carries the DECLARED name, never the directory basename, so a
  # runner still resolving the basename finds nothing.
  voe_container_start "$name" "$declared" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
