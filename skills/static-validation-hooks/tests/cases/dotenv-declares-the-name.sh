# Case: dotenv-declares-the-name
#
# Spec: US2 acceptance 2 — "Given a project `.env` setting COMPOSE_PROJECT_NAME
# and no exported variable, When the runner resolves the project, Then it
# resolves that value."
#
# The `.env` source is the other silent-miss door of the old two-source rule,
# and it is the reason the name cache fingerprints `.env` even though `.env` is
# not a Compose file and the plan's fingerprint list did not mention it: editing
# it changes the project name with no Compose file touched.
#
# Shape: a compose.yml with no `name:`, a `.env` naming the project, no exported
# variable, and a container carrying the `.env` value.
#
# Discriminating against the runner before this phase: the basename rule
# resolves the directory name, no container carries it, warning.

CASE_DESC="a project name coming from the project .env"
CASE_EXPECT="silence"

case_body() {
  local declared="$PROJECT_NAME-dotenv" name="$PROJECT_NAME-svc"
  VOE_NO_CPN=1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  cat >"$PROJECT_DIR/compose.yml" <<YML
services:
  app:
    image: $VOE_IMAGE
    command: sleep 900
YML
  printf 'COMPOSE_PROJECT_NAME=%s\n' "$declared" >"$PROJECT_DIR/.env"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$declared" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
