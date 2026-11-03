# Case: shell-answer-dropped-with-the-container
#
# Spec: FR-005a — "A container that cannot host the provenance evidence MUST
# keep being validated, by a weaker rule that the agent is told about, rather
# than stop being validated at all" — and FR-007, which requires a stack
# recreated since the last edit to validate on the first subsequent edit.
#
# Shape, three edits:
#   1. a container WITH a shell     -> silence; the id and `shell: yes` are cached
#   2. the container is removed     -> warning; the dead id is dropped
#   3. a replacement with NO shell  -> the finding must reach the agent
#
# The defect is in step 2. Whether a container can host the provenance wrapper
# is a fact about ONE container, probed once and cached beside its id; dropping
# the id without dropping that answer leaves the replacement inheriting it. The
# runner then wraps every call in a `sh -c` the new image cannot run, reads the
# failure as "the call never got inside", and warns that it could not establish
# why — on every edit, for as long as the state directory lives. The service has
# a working validator and is never asked to run it again. Nothing recovers,
# because the probe that would fix it is skipped precisely when its answer is
# already cached.
#
# Expected: a violation carrying the finding. Silence would be worse than the
# warning, and the warning is what the defect produces.

CASE_DESC="a shell-less replacement must not inherit the removed container's shell answer"
CASE_EXPECT="violation"

case_body() {
  local first="$PROJECT_NAME-svc-a" second="$PROJECT_NAME-svc-b"
  printf 'REQUIRED_MARKER present\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check grep -q REQUIRED_MARKER "/work/$F" ;;
  esac
}
RT

  voe_container_start "$first" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  # 1. Resolve and cache: the id, and that this container has a shell.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # 2. No container at all: the cached id is dropped on this edit, which is the
  #    edit the shell answer has to be dropped on too.
  voe_container_rm "$first"
  printf 'REQUIRED_MARKER still present\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "warning" ]; then
    printf '    setup failed: the empty stack was %s, expected warning\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # 3. The replacement has a working validator and no shell, and the file now
  #    fails it. The finding must arrive.
  voe_container_start "$second" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1
  voe_container_remove_shell "$second" || return 1

  printf 'the marker is gone\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'exit 1' 'the validator own code' || return 1
  expect_stderr reject 'could not establish why' 'a wrapper failure read as an unknown cause' || return 1
  return 0
}
