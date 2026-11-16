# Case: scaled-service-two-containers
#
# Spec: plan D3 — the label-filtered `docker ps` is read as a SET and consumed
# whole. A scaled service runs several containers behind one pair of labels, so
# the cached id can be absent while several candidates exist, and the first line
# of the query cannot answer that question on its own.
#
# Shape, ordered so the outcome is not a coin toss:
#   1. start A alone and edit  -> A is the ONLY candidate, so A is what got cached
#   2. start B and C, remove A -> two candidates, neither of them the cached id
#   3. edit a file the validator rejects
#
# The assertion is a VIOLATION carrying the finding, not merely a warning
# avoided: it proves the runner consumed the whole set, took an acceptable
# candidate, retried, and let the finding through. A runner that read only the
# first line of the query would have no way to tell step 3 from "the container
# is alive and the call did not get inside it".
#
# Not asserted here, and deliberately: WHICH of B and C is chosen. The plan
# says "the first acceptable candidate" and candidate verification is Phase D.
#
# Discriminating against the runner before this phase: no nonce comes back from
# the dead cached id, and the classifier warns instead of retrying. Measured red.

CASE_DESC="a scaled service whose cached container is replaced by two siblings"
CASE_EXPECT="violation"

case_body() {
  local a="$PROJECT_NAME-svc-a" b="$PROJECT_NAME-svc-b" c="$PROJECT_NAME-svc-c"
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
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

  voe_container_start "$b" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1
  voe_container_start "$c" "$PROJECT_NAME" voe "$PROJECT_DIR" /work >/dev/null || return 1
  voe_container_rm "$a"

  # Confirm the fixture really is scaled before asserting anything about it: two
  # running containers behind one pair of labels, or this case proves nothing.
  local n
  n="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" \
       --filter "label=com.docker.compose.service=voe" | grep -c .)"
  if [ "$n" != "2" ]; then
    printf '    fixture failed: %s candidates behind the labels, expected 2\n' "$n" >&2
    printf '%s' "unexpected:fixture-not-scaled" >"$CASE_DIR/observed"
    return 1
  fi

  printf 'FORBIDDEN\n' >"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'forbidden token' 'the finding itself' || return 1
  return 0
}
