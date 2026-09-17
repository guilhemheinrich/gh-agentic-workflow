# Case: format-then-validate-shares-recovery
#
# Spec: FR-017 — "Cache invalidation MUST live where the container is executed
# in, not in the branch that classifies. A routing table that runs a formatter
# before a validator shares the same execution path, and a formatter that
# ignores its result MUST NOT leave a dead identifier cached for the validator
# that follows."
#
# Shape: a ROUTING TABLE branch of the common shape — `fix` then `check` — on a
# service whose container has been replaced since the last edit. The `fix` verb
# discards its own result by design, so it is the one that meets the dead
# identifier first.
#
# Expected: a violation carrying the finding. Two things have to be true for it:
# the dead identifier is dropped by the verb that met it, and the `check` that
# follows runs inside the replacement.
#
# HONEST LIMITATION. With the recovery inside the shared execution path, BOTH
# verbs repair the cache, so this case cannot tell "fix repaired it" from "check
# repaired it on its own". It pins the OUTCOME the requirement asks for, on the
# routing shape the requirement names. It discriminates against the arrangement
# the requirement rejects: measured against the runner before this phase, where
# invalidation keys on a synthetic 125 that `docker exec` never returns, neither
# verb repairs anything and the edit ends in a warning.

CASE_DESC="a format-then-validate branch meeting a replaced container"
CASE_EXPECT="violation"

case_body() {
  local a="$PROJECT_NAME-svc-a" b="$PROJECT_NAME-svc-b"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      fix sh -c 'test -f "$1"' _ "/work/$F"
      check sh -c 'if grep -q FORBIDDEN "$1"; then printf "%s:1: forbidden token\n" "$1"; exit 1; fi' _ "/work/$F"
      ;;
  esac
}
RT

  voe_container_start "$a" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  voe_container_rm "$a"
  voe_container_start "$b" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1

  printf 'FORBIDDEN\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'forbidden token' 'the finding itself' || return 1
  return 0
}
