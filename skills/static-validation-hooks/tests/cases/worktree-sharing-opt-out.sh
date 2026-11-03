# Case: worktree-sharing-opt-out
#
# Spec: FR-015 — "A consumer that deliberately shares one stack across checkouts
# MUST keep an explicit way to say so, and that statement MUST bypass FR-013."
# Also SC-006 ("a consumer that has opted into sharing a stack keeps
# validating") and SC-006a's sixth shape.
#
# The same fixture as `worktree-shares-the-main-stack`, and the same container:
# the ONLY difference is VALIDATE_WORKTREE=run. The identity test must then be
# waived entirely and the file must validate.
#
# The pair is what makes either half meaningful. A runner that refused
# everything would pass the first case and fail this one; a runner that refused
# nothing would pass this one and fail the first.

CASE_DESC="one stack shared across checkouts on purpose (VALIDATE_WORKTREE=run)"
CASE_EXPECT="silence"

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
  VOE_WORKTREE=run

  voe_worktree_fixture "$main" "$wt" "$declared" "$VOE_IMAGE" || {
    printf '%s' "unexpected:worktree-fixture-failed" >"$CASE_DIR/observed"; return 1; }

  PROJECT_DIR="$wt"
  printf 'edited in the worktree\n' >>"$wt/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$declared" voe "$main" /work >/dev/null || return 1

  # Silence alone is not proof: a runner that skipped the worktree outright
  # would also be silent, and an earlier draft of this case passed for exactly
  # that reason. The shim counts, so "validated" and "skipped" stop looking
  # alike from outside.
  local logf="$CASE_DIR/docker-calls.log"
  voe_docker_shim "$logf" || return 1

  run_hook "$wt/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1

  local exec_calls; exec_calls="$(voe_docker_calls "$logf" exec)"
  printf '    docker exec calls: %s\n' "$exec_calls" >&2
  if [ "${exec_calls:-0}" = "0" ]; then
    printf '    silent because nothing ran, not because the file was validated\n' >&2
    printf '%s' "unexpected:silent-without-validating" >"$CASE_DIR/observed"
    return 1
  fi
  return 0
}
