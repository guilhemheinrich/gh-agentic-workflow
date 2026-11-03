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
# ── What this case used to prove, and why that was not FR-017 ────────────────
#
# It asserted the outcome alone: a violation carrying the finding. But `check`
# recovers on its own, so deleting the `fix` line from the routing table left
# the case green — it was pinning the CHECK's recovery and calling it the
# formatter's. A case that passes when the thing it names is removed is a green
# nobody earned, which is the defect this whole feature exists to remove.
#
# ── What it proves now ───────────────────────────────────────────────────────
#
# The outcome cannot separate the two arrangements, because both end in the same
# violation. The ORDER of Docker calls can, and it is visible from outside
# through the counting shim: the two verbs run distinguishable commands, and the
# log says which one paid for the resolution.
#
#   invalidation in the shared execution path (FR-017 satisfied):
#     exec <fix cmd>   fails on the dead id
#     ps               ONE resolution, paid for by `fix`
#     exec <fix cmd>   the retry, inside the replacement
#     exec <check cmd> the hot path, on the repaired cache
#
#   invalidation in the classifier instead (what FR-017 forbids):
#     exec <fix cmd>   fails, and `fix` discards its result, repairing nothing
#     exec <check cmd> fails on the same dead id
#     ps               the resolution, paid for by `check`
#     exec <check cmd> the retry
#
# So: exactly one `ps`; exactly two `fix` executions, which happen only if `fix`
# itself retried inside the replacement; exactly one `check` execution; and that
# one after the `ps`, never before it. Delete the `fix` line from the routing
# table and the two-execution assertion fails; move the recovery back into
# `check` and the count and the ordering both fail.

CASE_DESC="a format-then-validate branch meeting a replaced container"
CASE_EXPECT="violation"

case_body() {
  local a="$PROJECT_NAME-svc-a" b="$PROJECT_NAME-svc-b" logf="$CASE_DIR/docker-calls.log"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  # The two verbs must be told apart in the log, so their commands carry
  # different markers: VOE_FORMATTER for `fix`, FORBIDDEN for `check`.
  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      fix sh -c 'test -f "$1" # VOE_FORMATTER' _ "/work/$F"
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

  voe_docker_shim "$logf" || return 1
  printf 'FORBIDDEN\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'forbidden token' 'the finding itself' || return 1

  # ── who paid for the resolution ────────────────────────────────────────────
  local ps_calls fix_execs check_execs ps_line check_line
  ps_calls="$(voe_docker_calls "$logf" ps)"
  fix_execs="$(grep -c 'VOE_FORMATTER' "$logf" 2>/dev/null | tr -d ' \n')"
  check_execs="$(grep -c 'FORBIDDEN' "$logf" 2>/dev/null | tr -d ' \n')"
  ps_line="$(grep -n '^ps ' "$logf" 2>/dev/null | head -n1 | cut -d: -f1)"
  check_line="$(grep -n 'FORBIDDEN' "$logf" 2>/dev/null | head -n1 | cut -d: -f1)"
  printf '    docker calls: ps=%s fix-execs=%s check-execs=%s (ps at line %s, first check at line %s)\n' \
    "$ps_calls" "$fix_execs" "$check_execs" "${ps_line:-none}" "${check_line:-none}" >&2

  voe_assert_tick
  if [ "$ps_calls" != "1" ]; then
    printf '    expected exactly 1 resolution for the whole edit, got %s\n' "$ps_calls" >&2
    printf '%s' "unexpected:resolutions-$ps_calls" >"$CASE_DIR/observed"
    return 1
  fi

  voe_assert_tick
  if [ "$fix_execs" != "2" ]; then
    printf '    expected the formatter to run twice — once on the dead id, once on the\n' >&2
    printf '    replacement it resolved itself — got %s\n' "$fix_execs" >&2
    printf '%s' "unexpected:fix-execs-$fix_execs" >"$CASE_DIR/observed"
    return 1
  fi

  voe_assert_tick
  if [ "$check_execs" != "1" ]; then
    printf '    expected the validator to run once, on the cache the formatter repaired,\n' >&2
    printf '    got %s executions\n' "$check_execs" >&2
    printf '%s' "unexpected:check-execs-$check_execs" >"$CASE_DIR/observed"
    return 1
  fi

  voe_assert_tick
  if [ -z "$ps_line" ] || [ -z "$check_line" ] || [ "$check_line" -lt "$ps_line" ]; then
    printf '    the validator ran before the resolution: the formatter did not share it\n' >&2
    sed 's/^/      | /' "$logf" >&2
    printf '%s' "unexpected:check-ran-before-resolution" >"$CASE_DIR/observed"
    return 1
  fi
  return 0
}
