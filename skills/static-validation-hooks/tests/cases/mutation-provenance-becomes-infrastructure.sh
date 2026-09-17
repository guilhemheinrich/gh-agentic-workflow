# Case: mutation-provenance-becomes-infrastructure
#
# Spec: US3 acceptance 2 — "Given the suite mutates the runner to classify every
# exit 1 as infrastructure, When it runs, Then the case covering a validator
# that legitimately exits 1 fails. The mutation is applied by the suite to a
# copy of the runner, so the guard is exercised rather than asserted."
# Plan D8, FR-021.
#
# ── Why this case exists ─────────────────────────────────────────────────────
#
# Every other case asserts an OUTCOME. Not one of them establishes that the
# suite would NOTICE if the classifier stopped working: a suite whose guards
# cannot fail is a green nobody earned, which is the same shape as the defect
# this feature exists to remove. So the classifier is broken on purpose, in a
# copy, and the suite is replayed against the break.
#
# ── The site and the operator, named on purpose ──────────────────────────────
#
# SITE     the provenance test in `exec_reached_inside`, the one line that asks
#          whether the nonce came back:
#
#              case "$out" in *"$_NONCE"*) return 0 ;; esac
#
# OPERATOR delete it. What remains is `return 1` for every failed exec in a
#          service that has a shell — an UNCONDITIONAL infrastructure verdict,
#          which is precisely the contract this feature installed.
#
# They are named rather than derived because a later change to the runner that
# MOVES that line must fail this case loudly instead of silently mutating
# nothing and reporting a pass. Hence the match count below: exactly one site,
# or the case fails. Zero means the runner moved and this case has gone blind;
# several means the operator is not the single substitution the plan specifies.
#
# ── What it asserts, and what it deliberately does not ───────────────────────
#
# It replays the two guard cases against the mutant and requires each to FAIL,
# with the specific transformation the plan names: `violation` becomes
# `warning`. Asserting only "the nested run failed" would be satisfied by a
# Docker hiccup or a broken fixture, so the assertion reads the harness's own
# verdict line — `expected violation, observed warning`.
#
# It carries NO copy of the decision table. It does not know which exit codes or
# which messages the runner considers infrastructure, any more than the other
# cases do; it knows only that two cases which pass against the runner must fail
# against a runner whose provenance test has been removed. The unmutated half of
# that pair is not re-run here — it is those same two cases, in this very
# matrix, a few rows above.

CASE_DESC="the suite fails when the provenance test is removed from a copy of the runner"
CASE_EXPECT="mutant-caught"

# The exact line that is deleted, and what replaces it. Leading indentation is
# part of both, so a coincidental match elsewhere in the file cannot be hit.
MUT_SITE='    case "$out" in *"$_NONCE"*) return 0 ;; esac'
MUT_REPL='    : # MUTANT: provenance deleted — every failed exec reads as infrastructure'

# The guard cases replayed against the mutant. Both pass against the real runner
# in this same matrix; both must fail against the mutant.
MUT_GUARDS="validator-exit-1-with-findings
validator-output-looks-like-a-daemon-error"

case_body() {
  local mutant="$CASE_DIR/mutant-runner.sh" countf="$CASE_DIR/mutation.count"
  local hits="" g="" out="" rc=0

  # A nested run.sh must never select this case, or it would recurse. Nothing
  # below passes --all, but the guard is cheaper than discovering the recursion.
  if [ "${VOE_MUTATION_DEPTH:-0}" != "0" ]; then
    printf '    refusing to nest the mutation case inside itself\n' >&2
    printf '%s' "unexpected:mutation-case-nested" >"$CASE_DIR/observed"
    return 1
  fi

  # 1. Exactly one site, in the PRISTINE runner the suite normally drives.
  voe_assert_tick
  hits="$(grep -c -F -- "$MUT_SITE" "$RUNNER_SRC" 2>/dev/null | tr -d ' \n')"
  if [ "$hits" != "1" ]; then
    printf '    the mutation site matched %s line(s) in %s, expected exactly 1\n' \
      "${hits:-0}" "$RUNNER_SRC" >&2
    printf '    site: %s\n' "$MUT_SITE" >&2
    printf '    the provenance test moved or changed shape — this case is blind until\n' >&2
    printf '    the site above is updated to the line exec_reached_inside now uses.\n' >&2
    printf '%s' "unexpected:mutation-site-matched-$hits" >"$CASE_DIR/observed"
    return 1
  fi

  # 2. Apply it. awk with index/substr, not sed: the site carries `$`, `"` and
  #    `*`, every one of which a regex engine would read as syntax.
  awk -v pat="$MUT_SITE" -v rep="$MUT_REPL" '
    {
      i = index($0, pat)
      if (i > 0) { n++; $0 = substr($0, 1, i - 1) rep substr($0, i + length(pat)) }
      print
    }
    END { printf "%d\n", n + 0 > "/dev/stderr" }
  ' "$RUNNER_SRC" >"$mutant" 2>"$countf" || {
    printf '    the mutation could not be applied\n' >&2
    printf '%s' "unexpected:mutation-not-applied" >"$CASE_DIR/observed"
    return 1
  }

  voe_assert_tick
  local applied; applied="$(tr -d ' \n' <"$countf" 2>/dev/null)"
  if [ "$applied" != "1" ]; then
    printf '    the operator replaced %s site(s), expected exactly 1\n' "${applied:-0}" >&2
    printf '%s' "unexpected:mutation-applied-$applied" >"$CASE_DIR/observed"
    return 1
  fi

  # 3. The mutant must still be a runnable script, and must actually differ.
  voe_assert_tick
  if ! bash -n "$mutant" 2>/dev/null; then
    printf '    the mutant does not parse\n' >&2
    printf '%s' "unexpected:mutant-does-not-parse" >"$CASE_DIR/observed"
    return 1
  fi
  voe_assert_tick
  if cmp -s "$mutant" "$RUNNER_SRC"; then
    printf '    the mutant is byte-identical to the runner\n' >&2
    printf '%s' "unexpected:mutant-identical" >"$CASE_DIR/observed"
    return 1
  fi
  printf '    mutated exec_reached_inside: 1 site, %s\n' "$(basename "$mutant")" >&2

  # 4. Replay the guards against the mutant. Each must fail, and must fail by
  #    turning a violation into a warning — the harness's own verdict line.
  for g in $MUT_GUARDS; do
    out="$(VOE_RUNNER="$mutant" VOE_MUTATION_DEPTH=1 \
      bash "$TESTS_DIR/run.sh" --case "$g" --image "$VOE_IMAGE" 2>&1)"
    rc=$?
    voe_assert_tick
    if [ "$rc" -eq 0 ]; then
      printf '    %s still PASSED against the mutant — the suite cannot see the break\n' "$g" >&2
      printf '%s\n' "$out" | sed 's/^/      | /' >&2
      printf '%s' "unexpected:mutant-not-caught-$g" >"$CASE_DIR/observed"
      return 1
    fi
    voe_assert_tick
    if ! printf '%s' "$out" | grep -q 'expected violation, observed warning'; then
      printf '    %s failed against the mutant, but not by violation -> warning\n' "$g" >&2
      printf '%s\n' "$out" | sed 's/^/      | /' >&2
      printf '%s' "unexpected:mutant-failed-for-another-reason-$g" >"$CASE_DIR/observed"
      return 1
    fi
    printf '    %s: violation -> warning against the mutant (caught)\n' "$g" >&2
  done

  printf '%s' "$CASE_EXPECT" >"$CASE_DIR/observed"
  return 0
}
