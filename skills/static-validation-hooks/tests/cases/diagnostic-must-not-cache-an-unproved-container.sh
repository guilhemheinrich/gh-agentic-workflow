# Case: diagnostic-must-not-cache-an-unproved-container
#
# Spec: FR-013 — "When it resolves a container, the runner MUST establish that
# the container's copy of the edited file is this checkout's copy." The cache is
# what makes that a promise about every LATER edit too: an identifier written
# down without the proof hands the unchecked hot path to every edit that
# follows, and the proof is never taken again.
#
# ── The skipped proof, and why it is skipped ─────────────────────────────────
#
# The identity test is allowed to be skipped and the container accepted anyway,
# in the permissive direction, when the edit cannot afford the inspection or
# when there is no host file to test against. That is deliberate: refusing there
# would turn a slow machine into a stream of checkout-mismatch warnings about
# containers that are in fact this checkout's.
#
# What does not follow is CACHING that acceptance. The skip buys one edit a
# container; the cache buys every edit after it a container nobody checked.
#
# ── Reaching it from outside ─────────────────────────────────────────────────
#
# The reachable skip is "no host file to test against", and the door to it is
# the runner's own human diagnostic: `--check <path>` routes and runs whatever
# path it is given, including one that does not exist — which is exactly what a
# developer types when checking that a branch of the routing table fires at all.
# The hook itself refuses a missing file earlier, and the budget skip needs the
# budget to expire inside the sub-second window between the listing returning
# and the inspection starting, so this is the one of the two that a test can
# reach deterministically.
#
# So: a foreign container (it binds ANOTHER directory, whose copy of app.txt
# carries a finding), one diagnostic command on a path that does not exist, and
# then an ordinary edit by the agent. The agent's own file is clean.
#
#   cached anyway  the hot path runs in the foreign container and the agent is
#                  handed a finding about a file it did not write
#   not cached     the edit resolves, the identity test runs, the container is
#                  refused, and the agent is told the file was not validated
#
# The diagnostic is invoked exactly as a human invokes it, from the project
# root, with this case's own TMPDIR so it writes into the same state the hook
# reads. Its own output is not asserted on — it is a human CLI path, not an
# agent-visible one, and this case cares only about what it leaves behind.

CASE_DESC="a diagnostic on a missing path must not cache the container it did not check"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc" base elsewhere

  # The two entry points must agree on the project root, or they write into two
  # different state directories and this case would assert nothing. The hook
  # takes the root from the payload's own spelling; `--check` takes it from
  # `pwd`, which has already normalised the sandbox path (`…/T//voe-test-…`).
  # So the physical spelling is used throughout — the same precaution the
  # worktree cases take, for the same reason.
  base="$(cd "$CASE_DIR" && pwd -P)"
  PROJECT_DIR="$base/$PROJECT_NAME"
  elsewhere="$base/elsewhere"

  mkdir -p "$elsewhere" || return 1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"
  printf 'FORBIDDEN — another checkout entirely\n' >"$elsewhere/app.txt"

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

  # Labelled with this project, and binding a directory that is NOT this one.
  voe_container_start "$name" "$PROJECT_NAME" voe "$elsewhere" /work >/dev/null || return 1

  # The human diagnostic, on a path that does not exist.
  (
    cd "$PROJECT_DIR" || exit 90
    env -u COMPOSE_PROJECT_NAME -u COMPOSE_FILE -u COMPOSE_PROFILES -u COMPOSE_ENV_FILES \
      TMPDIR="$CASE_TMPDIR" \
      VALIDATE_BUDGET_S="${VOE_BUDGET_S:-10}" \
      COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
      bash "$RUNNER_COPY" --check does-not-exist.txt
  ) >"$CASE_DIR/diagnostic.out" 2>&1
  printf '    diagnostic on a missing path: rc=%s\n' "$?" >&2

  # Now the agent edits its own, clean file.
  printf 'still clean\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr reject 'forbidden token' "another checkout's finding, about this agent's file" || return 1
  expect_stderr want 'does not read this checkout' 'the checkout mismatch named' || return 1
  return 0
}
