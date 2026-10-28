#!/usr/bin/env bash
# lifecycle.test.sh — run the INSTALLED lifecycle hook against a fixture repo.
#
# Proves, on the files the installer copies (not on the skill's templates):
#   - every run exits 0 and never emits a deny or a permission decision,
#   - each fact is asked exactly once, then never again,
#   - silence when the turn ends on a question (and the fact is still asked later),
#   - silence on stop_hook_active, without .linear.json, after `unavailable`,
#   - the installer is idempotent and keeps edited templates,
#   - the settings registration holds a Stop hook and nothing else.
# Run it through run-in-docker.sh.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/consumer"
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
nok()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else nok "$1" "${3:-}"; fi; }

OUT="" RC=0 MS=0
hook() { # [LAST_MESSAGE] [STOP_HOOK_ACTIVE]
  local msg="${1:-Done.}" active="${2:-false}" t0 t1
  local payload
  payload="$(jq -n --arg cwd "$REPO" --arg m "$msg" --argjson a "$active" \
    '{session_id: "s1", cwd: $cwd, stop_hook_active: $a, last_assistant_message: $m}')"
  t0="${EPOCHREALTIME/./}"
  OUT="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$REPO" "$REPO/.agents/hooks/linear-lifecycle.sh" 2>"$WORK/stderr")"
  RC=$?
  t1="${EPOCHREALTIME/./}"
  MS=$(( (t1 - t0) / 1000 ))
  # Invariants checked on EVERY run.
  [[ "$RC" == 0 ]] || nok "hook exit code is 0" "got $RC: $(cat "$WORK/stderr")"
  if grep -qiE 'deny|permissionDecision' <<<"$OUT"; then nok "hook never emits a deny" "$OUT"; fi
  if [[ -n "$OUT" ]] && ! printf '%s' "$OUT" | jq -e '.decision == "block" and (.reason | type) == "string" and (keys | length) == 2' >/dev/null 2>&1; then
    nok "hook output is only {decision: block, reason}" "$OUT"
  fi
  ALL_OUT+="$OUT"$'\n'
}
ALL_OUT=""
asks() { local r; r="$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)"; [[ "$r" == *"$1"* ]]; }

# ── Fixture: a consumer repo with spec-kit artifacts ────────────────────────
mkdir -p "$REPO" "$WORK/bin"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.test
git -C "$REPO" config user.name test
git -C "$REPO" remote add origin git@example.test:acme/widget-api.git
echo '{"team":"Tiger Team","project":"Widget API"}' >"$REPO/.linear.json"
mkdir -p "$REPO/specs/042-webhook-202"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init
git -C "$REPO" switch -qc 042-webhook-202

# A gh stub whose answer the test controls; absent file = no PR.
cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ -f "$GH_STUB_PR" ]] && cat "$GH_STUB_PR" || exit 1
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" GH_STUB_PR="$WORK/pr.json" LINEAR_LIFECYCLE_GH_TTL=0

echo "install"
bash "$SKILL_DIR/scripts/install-lifecycle.sh" "$REPO" >"$WORK/install1.log" 2>&1
check "installer copies the hook" '[[ -x "$REPO/.agents/hooks/linear-lifecycle.sh" ]]'
check "installer copies 3 templates and phases.json" '[[ $(ls "$REPO/.agents/linear" | wc -l) -eq 4 ]]'
check "settings register exactly one Stop hook" '[[ $(jq "[.hooks.Stop[].hooks[]] | length" "$REPO/.claude/settings.json") == 1 ]]'
check "settings register no other hook event" '[[ $(jq -c ".hooks | keys" "$REPO/.claude/settings.json") == "[\"Stop\"]" ]]'
echo "edited by the consumer" >>"$REPO/.agents/linear/specify.issue.md"
bash "$SKILL_DIR/scripts/install-lifecycle.sh" "$REPO" >"$WORK/install2.log" 2>&1
check "re-install keeps one Stop hook" '[[ $(jq "[.hooks.Stop[].hooks[]] | length" "$REPO/.claude/settings.json") == 1 ]]'
check "re-install keeps edited templates" 'grep -q "edited by the consumer" "$REPO/.agents/linear/specify.issue.md"'
check "installed hook does not reference the skill" '! grep -q "skills/linear-tracker" "$REPO"/.agents/hooks/*.sh'
git -C "$REPO" add -A && git -C "$REPO" commit -qm "chore: install linear lifecycle hook"

echo "no fact yet"
hook; check "empty spec folder: silent" '[[ -z "$OUT" ]]'

echo "specify"
printf '# Feature Specification: Webhook answers 202\n' >"$REPO/specs/042-webhook-202/spec.md"
hook "Spec written. Should I continue?"
check "turn ending on a question: silent" '[[ -z "$OUT" ]]'
hook "Done." true
check "stop_hook_active: silent" '[[ -z "$OUT" ]]'
hook
check "spec.md appears: asks to create the issue" 'asks "spec.md exists" && asks "Webhook answers 202" && asks "Tiger Team"'
check "specify names its template" 'asks "specify.issue.md"'
hook
check "same fact again: silent" '[[ -z "$OUT" ]]'

echo "record"
rec="$REPO/.agents/hooks/linear-record.sh"
check "record created" '[[ $("$rec" "$REPO/specs/042-webhook-202" created TT-412 https://linear.app/t/TT-412) == recorded ]]'
check "record is idempotent" '[[ $("$rec" "$REPO/specs/042-webhook-202" created TT-412 https://linear.app/t/TT-412) == already-recorded ]]'
check "record refuses a bad identifier" '! "$rec" "$REPO/specs/042-webhook-202" in_progress nope 2>/dev/null'

echo "implement"
printf -- '- [ ] T001 test\n- [ ] T002 code\n' >"$REPO/specs/042-webhook-202/tasks.md"
hook; check "tasks.md with nothing ticked: silent" '[[ -z "$OUT" ]]'
printf -- '- [x] T001 test\n- [ ] T002 code\n' >"$REPO/specs/042-webhook-202/tasks.md"
hook
check "first ticked task: asks In Progress" 'asks "1/2 tasks are ticked" && asks "TT-412" && asks "En cours"'
check "implement carries the no-regression guard" 'asks "never goes backwards"'
printf -- '- [x] T001 test\n- [x] T002 code\n' >"$REPO/specs/042-webhook-202/tasks.md"
hook; check "more ticks, same fact: silent" '[[ -z "$OUT" ]]'
"$rec" "$REPO/specs/042-webhook-202" in_progress TT-412 >/dev/null

echo "pr-open"
hook; check "no PR: silent" '[[ -z "$OUT" ]]'
echo '{"number":7,"state":"OPEN","url":"https://example.test/acme/widget-api/pull/7"}' >"$WORK/pr.json"
hook
check "PR opens: asks In Review with the link" 'asks "PR #7 is open" && asks "pull/7" && asks "pr-open.comment.md"'
check "pr-open carries the no-regression guard" 'asks "never goes backwards"'
check "PR-open hook stays under 200 ms" '(( MS < 200 ))' "took ${MS} ms"
hook; check "same PR again: silent" '[[ -z "$OUT" ]]'
"$rec" "$REPO/specs/042-webhook-202" in_review TT-412 https://example.test/acme/widget-api/pull/7 >/dev/null
hook; check "everything recorded: silent" '[[ -z "$OUT" ]]'

echo "unavailable"
mkdir -p "$REPO/specs/043-retry"
printf '# Retry policy\n' >"$REPO/specs/043-retry/spec.md"
git -C "$REPO" switch -qc 043-retry
"$rec" "$REPO/specs/043-retry" unavailable >/dev/null
hook; check "unavailable recorded: silent for that spec" '[[ -z "$OUT" ]]'

echo "no .linear.json"
mkdir -p "$REPO/specs/044-dlq"; printf '# DLQ\n' >"$REPO/specs/044-dlq/spec.md"
git -C "$REPO" switch -qc 044-dlq
mv "$REPO/.linear.json" "$WORK/linear.json.bak"
hook; check "no .linear.json: silent" '[[ -z "$OUT" ]]'
mv "$WORK/linear.json.bak" "$REPO/.linear.json"
hook; check "config restored: asks for 044" 'asks "specs/044-dlq/spec.md"'

echo "fallback on uncommitted specs (non-spec branch)"
git -C "$REPO" switch -qc chore/misc
mkdir -p "$REPO/specs/045-metrics"; printf '# Metrics\n' >"$REPO/specs/045-metrics/spec.md"
hook; check "uncommitted spec on a free branch: asks for 045" 'asks "specs/045-metrics/spec.md"'

echo "worktree shares the asked keys"
git -C "$REPO" add -A >/dev/null && git -C "$REPO" commit -qm wip
git -C "$REPO" worktree add -q "$WORK/wt" 044-dlq
saved="$REPO"; REPO="$WORK/wt"
rm -f "$WORK/pr.json"
hook; check "a second worktree on 044 does not re-ask its specify fact" '[[ -z "$OUT" ]]'
REPO="$saved"

echo "takeover: a colleague created the issue by hand and already ticked tasks"
git -C "$REPO" switch -qc 046-takeover 044-dlq
mkdir -p "$REPO/specs/046-takeover"
printf '# Takeover\n' >"$REPO/specs/046-takeover/spec.md"
printf -- '- [x] T001\n- [x] T002\n- [ ] T003\n' >"$REPO/specs/046-takeover/tasks.md"
"$rec" "$REPO/specs/046-takeover" linked TT-500 https://linear.app/t/TT-500 >/dev/null
hook
check "linked by hand: next stop catches up on In Progress" 'asks "2/3 tasks are ticked" && asks "TT-500" && asks "never goes backwards"'
check "linked by hand: specify is not asked" '! asks "spec.md exists"'

echo "global invariants"
check "no run ever emitted a deny" '! grep -qiE "deny|permissionDecision" <<<"$ALL_OUT"'
count="$(printf '%s' "$ALL_OUT" | grep -c '"decision"' || true)"
check "exactly 6 asks over the whole scenario (specify 042, implement, pr-open, specify 044, specify 045, implement 046)" '[[ "$count" == 6 ]]' "got $count"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
