# Case: worktree-shares-the-main-stack
#
# Spec: US2 acceptance 6 and FR-016 — "Given a linked worktree of a repository
# whose Compose name comes from the Compose file, and a stack running only for
# the main checkout, When the agent edits a file in the worktree, Then the hook
# does NOT validate against the main checkout's container, and says the file was
# not validated."
#
# This is the regression the project-name fix would have introduced on its own,
# and the reason D6 and D5 ship together. The old worktree rule skipped only
# when COMPOSE_PROJECT_NAME was exported, on the stated grounds that the name
# otherwise came from the worktree's OWN directory. Resolving the name through
# Compose removes that ground: the worktree carries the same committed
# compose.yml as its main checkout, so it now resolves the main checkout's
# stack, whose bind mount holds the MAIN copy of the edited file. A pass or a
# fail there describes a file the agent did not write.
#
# Shape: main checkout + linked worktree, one container bind-mounting the MAIN
# checkout under the declared project name, VALIDATE_WORKTREE=auto, edit in the
# worktree.
#
# The outcome alone does not discriminate — a runner that resolved the wrong
# name would also warn — so the case also asserts WHAT the agent is told: the
# checkout mismatch, not a stopped stack.

CASE_DESC="a linked worktree resolving its main checkout's stack"
CASE_EXPECT="warning"

case_body() {
  local declared="$PROJECT_NAME-shared" name="$PROJECT_NAME-svc"
  local base main wt
  # The physical spelling: git answers `rev-parse --show-toplevel` with the
  # PHYSICAL path, while $CASE_DIR is reached through /var -> /private/var on
  # macOS. A fixture mixing the two makes the runner refuse the file as "outside
  # the project root" and the case would pass by validating nothing.
  base="$(cd "$CASE_DIR" && pwd -P)"
  main="$base/main"; wt="$base/wt"
  VOE_NO_CPN=1

  voe_worktree_fixture "$main" "$wt" "$declared" "$VOE_IMAGE" || {
    printf '%s' "unexpected:worktree-fixture-failed" >"$CASE_DIR/observed"; return 1; }

  # The hook runs from the WORKTREE, on the worktree's own copy of the file.
  PROJECT_DIR="$wt"
  printf 'edited in the worktree\n' >>"$wt/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  # The only container is the MAIN checkout's.
  voe_container_start "$name" "$declared" voe "$main" /work >/dev/null || return 1

  run_hook "$wt/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'does not read this checkout' 'the checkout mismatch named' || return 1
  expect_stderr reject 'has no running container' 'a stopped stack blamed for a shared one' || return 1
  return 0
}
