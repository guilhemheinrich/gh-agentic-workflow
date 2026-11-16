#!/usr/bin/env bash
# github-daemon.test.sh — one daemon cycle at a time over a GitHub PR: a check
# that fails wakes at once, a merge opens the build phase, the build verdict
# closes the subscription.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"
export PRW_SETTLE_SECONDS=30
T0=1793372000
cycle() { PRW_NOW="$1" "$PRW" daemon once; }
unread() { lib "events_unread $1" | wc -l | tr -d ' '; }

fx_pr_open
"$PRW" subscribe "$FX_KEY" 42 --session s1 >/dev/null
cycle "$T0"
check "baseline cycle releases nothing" '[ "$(unread s1)" = 0 ]'
check "baseline writes the snapshot under the host-prefixed key" '[ -f "$PRW_STATE_DIR/snapshots/github:octo-org__cockpit__42.json" ]'

# lint ends red on the same head: a failure is released in the same cycle.
fx_list "repos/$FX_REPO/commits/$FX_HEAD/check-runs" '{"check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "completed_at": "2026-11-02T10:00:00Z", "html_url": "https://github.com/octo-org/cockpit/runs/1"},
  {"name": "lint", "status": "completed", "conclusion": "failure", "completed_at": "2026-11-02T10:05:00Z", "html_url": "https://github.com/octo-org/cockpit/runs/2"}]}'
cycle $((T0 + 10))
check "a failing check is released in the same cycle" '[ "$(unread s1)" = 1 ] && lib "events_unread s1" | grep -q "lint.*FAILED"' "$(lib "events_unread s1")"
lib 'events_ack s1 1'

# The PR is merged: the subscription enters the build phase on the merge commit.
fx_put "repos/$FX_REPO/pulls/42" '{"number": 42, "state": "closed", "merged": true, "title": "t",
  "html_url": "https://github.com/octo-org/cockpit/pull/42", "head": {"sha": "'"$FX_HEAD"'"},
  "base": {"sha": "bbb222", "ref": "staging"}, "merge_commit_sha": "'"$FX_MERGE"'", "mergeable": null}'
fx_list "repos/$FX_REPO/commits/$FX_MERGE/check-runs" '{"check_runs": [
  {"name": "deploy", "status": "in_progress", "conclusion": null, "started_at": "2026-11-02T11:00:00Z", "html_url": "https://github.com/octo-org/cockpit/runs/9"}]}'
fx_list "repos/$FX_REPO/commits/$FX_MERGE/statuses" '[]'
cycle $((T0 + 20))
check "the merge wakes at once" '[ "$(unread s1)" = 1 ] && lib "events_unread s1" | grep -q "cockpit#42 merged"' "$(lib "events_unread s1")"
lib 'events_ack s1 1'
check "a merged PR is followed on its merge commit" '"$PRW" list --session s1 | grep -q "^github:octo-org/cockpit#42 build staging@mrg111mrg111 s1"' "$("$PRW" list --session s1)"
cycle $((T0 + 25))
check "a running deploy wakes nobody" '[ "$(unread s1)" = 0 ]' "$(lib "events_unread s1")"

# The deploy fails: one urgent line.
fx_list "repos/$FX_REPO/commits/$FX_MERGE/check-runs" '{"check_runs": [
  {"name": "deploy", "status": "completed", "conclusion": "failure", "completed_at": "2026-11-02T11:05:00Z", "html_url": "https://github.com/octo-org/cockpit/runs/9"}]}'
cycle $((T0 + 40))
out="$(lib "events_unread s1")"
check "the failed deploy leaves at once, with its link" '[ "$(unread s1)" = 1 ] && printf "%s" "$out" | grep -q "after merge into staging.*deploy.*FAILED.*runs/9"' "$out"
check "the build verdict closes the subscription" '[ -z "$("$PRW" list --session s1)" ]'

summary
