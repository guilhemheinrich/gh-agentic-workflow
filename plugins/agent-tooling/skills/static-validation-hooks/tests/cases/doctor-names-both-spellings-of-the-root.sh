# Case: doctor-names-both-spellings-of-the-root
#
# `--doctor` must say when this project root has two spellings, and must say
# what that costs, because the cost is SILENCE and silence is what a correctly
# installed hook produces on a clean file.
#
# The defect itself — GRV-symlinked-project-path-makes-7d96 — is declared and
# deliberately NOT fixed here: `find_project_root` takes git's top-level, git
# answers it physically with symlinks resolved, and the hook entry compares the
# payload path to it as a string. An edit arriving through the unresolved
# spelling is read as sitting outside the project and returns through the silent
# arm. This case asserts the DIAGNOSTIC, not the fix, so it stays green when the
# defect is eventually repaired — the pair of spellings still differs, and the
# diagnostic still owes the human the pair.
#
# Measured on this machine before the check was written, on a throwaway
# repository under a symlinked directory:
#
#   git -C <link>/sub rev-parse --show-toplevel  ->  /private/tmp/…/real
#   cd <link>/sub && pwd                         ->  /tmp/…/link/sub
#   payload <link>/sub/app.txt vs root /private/tmp/…/real -> prefix test fails
#
# Shape: one git repository, reached twice — once by its physical path, once
# through a symlink to it. Both polarities are asserted, and the negative is the
# one that keeps the check from being a line that always prints: a setup whose
# two spellings agree must NOT claim a mismatch.
#
# It drives `--doctor`, which no other case in this suite does. That is the gap
# this case closes as much as the check it asserts: a human CLI path the agent
# never sees was covered by nothing, so a regression in it was invisible.

CASE_DESC="--doctor names both spellings of a project root reached through a symlink"
CASE_EXPECT="doctor-ok"

case_body() {
  local base proj link
  # The PHYSICAL spelling of the sandbox: $CASE_DIR is reached through
  # /var -> /private/var on macOS, and a fixture mixing the two would make this
  # case pass for the wrong reason — it would find a spelling mismatch that the
  # harness introduced rather than one the symlink did.
  base="$(cd "$CASE_DIR" && pwd -P)"
  proj="$base/proj"
  link="$base/link"

  mkdir -p "$proj" || return 1
  : >"$proj/Makefile"
  printf 'clean\n' >"$proj/app.txt"
  git -C "$proj" init -q >/dev/null 2>&1 || {
    printf '%s' "unexpected:git-init-failed" >"$CASE_DIR/observed"; return 1; }
  git -C "$proj" add -A >/dev/null 2>&1 || return 1
  git -c user.name=voe -c user.email=voe@example.invalid -C "$proj" \
    commit -q -m "voe fixture" >/dev/null 2>&1 || {
      printf '%s' "unexpected:git-commit-failed" >"$CASE_DIR/observed"; return 1; }

  ln -s "$proj" "$link" || return 1

  # The fixture must really produce two spellings, or the case would assert
  # against a setup that cannot show the difference and would pass for free.
  if [ "$(cd "$link" && pwd -P)" != "$proj" ]; then
    printf '%s' "unexpected:symlink-does-not-resolve-to-the-project" >"$CASE_DIR/observed"
    return 1
  fi
  if [ "$(cd "$link" && pwd -L)" = "$proj" ]; then
    printf '%s' "unexpected:the-shell-resolved-the-symlink-itself" >"$CASE_DIR/observed"
    return 1
  fi

  PROJECT_DIR="$proj"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  # ── 1. The negative. One spelling: the diagnostic says so and stays quiet.
  VOE_DOCTOR_CWD="$proj"
  run_doctor
  expect_doctor want 'spelling +: one' 'the single-spelling line' || return 1
  expect_doctor reject 'spelling +: TWO' 'a mismatch claimed on a clean setup' || return 1
  expect_doctor reject 'SKIPPED IN SILENCE' 'the consequence announced on a clean setup' || return 1

  # ── 2. The positive. Same root, reached through the symlink.
  VOE_DOCTOR_CWD="$link"
  run_doctor
  expect_doctor want 'spelling +: TWO' 'the two-spelling verdict' || return 1
  expect_doctor want "resolved +: $proj\$" 'the resolved spelling printed' || return 1
  expect_doctor want "as reached +: $link\$" 'the unresolved spelling printed' || return 1
  # The consequence, not just the fact. A pair of paths with no sentence saying
  # what happens to an edit is a curiosity; this is the line that makes it a
  # finding.
  expect_doctor want 'SKIPPED IN SILENCE' 'the consequence stated' || return 1
  expect_doctor want 'GRV-symlinked-project-path-makes-7d96' 'the declared defect named' || return 1
  return 0
}
