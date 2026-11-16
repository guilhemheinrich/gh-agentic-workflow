# Case: resolver-override-keeps-validating
#
# Spec: US2 acceptance 5 and FR-019 — "A consumer override of the project
# resolver placed inside the routing-table markers MUST keep taking precedence
# after a runner upgrade, and MUST keep validating rather than being refused by
# FR-013."
#
# Two obligations in one sentence, and this case asserts both at once:
#
#   precedence  the override must beat everything, including an exported
#               COMPOSE_PROJECT_NAME — which IS exported here, naming a project
#               no container carries. Only the override can find the stack.
#   waiver      the container it names bind-mounts a DIFFERENT directory, so the
#               checkout-identity test would refuse it. A consumer who has taken
#               over resolution has taken over that question too.
#
# The two directories are not a contrivance: they are the shape of a consumer
# that resolves its own stack name because the runner cannot see how it was
# started. Silence here means the override won and was not second-guessed; a
# warning means one of the two obligations was dropped.

CASE_DESC="a ROUTING TABLE override of the resolver, over a foreign mount"
CASE_EXPECT="silence"

case_body() {
  local override="$PROJECT_NAME-override" name="$PROJECT_NAME-svc"
  local elsewhere="$CASE_DIR/elsewhere"

  printf 'clean\n' >"$PROJECT_DIR/app.txt"
  mkdir -p "$elsewhere" || return 1
  printf 'another checkout entirely\n' >"$elsewhere/app.txt"

  # Unquoted heredoc: the project name is interpolated, everything the RUNNER
  # must expand at run time is escaped.
  write_routing_table <<RT
compose_project() { printf '%s' '$override'; }

route() {
  case "\$REL" in
    *.txt) svc voe; check sh -c 'test -f "\$1"' _ "/work/\$F" ;;
  esac
}
RT

  # Labelled with the override's name, mounting a directory that is NOT this
  # project root.
  voe_container_start "$name" "$override" voe "$elsewhere" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
