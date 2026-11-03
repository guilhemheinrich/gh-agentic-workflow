#!/usr/bin/env bash
# github-real.test.sh — the GitHub provider against real payloads, so a field
# name remembered wrongly fails here. Provenance: fixtures/github-real/README.md.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"

RP="$SKILL_DIR/tests/fixtures/github-real"
R="cli/cli" N=14858 KEY="github:cli/cli"
SHA="$(jq -r .head.sha "$RP/pr.json")"
fx_put "repos/$R/pulls/$N" "$(cat "$RP/pr.json")"
fx_list "repos/$R/commits/$SHA/check-runs" "$(cat "$RP/check-runs.json")"
fx_list "repos/$R/commits/$SHA/statuses" "$(cat "$RP/statuses.json")"
fx_list "repos/$R/pulls/$N/reviews" "$(cat "$RP/reviews.json")"
fx_list "repos/$R/pulls/$N/comments" "$(cat "$RP/review-comments.json")"
fx_list "repos/$R/issues/$N/comments" "$(cat "$RP/issue-comments.json")"

SNAP="$WORK/real.json"
lib "snapshot_fetch $KEY $N >'$SNAP'" 2>/dev/null; rc=$?
check "snapshot of a real PR succeeds" '[ "$rc" = 0 ]' "rc=$rc"
check "a merged PR is MERGED" '[ "$(jq -r .state "$SNAP")" = MERGED ]'
check "the merge commit is the real merge_commit_sha" '[ "$(jq -r .merge_commit "$SNAP")" = "$(jq -r .merge_commit_sha "$RP/pr.json")" ]'
check "a clean mergeable PR has no conflict" '[ "$(jq -r .conflict "$SNAP")" = false ]'
check "check runs collapse by name" '[ "$(jq ".statuses | length" "$SNAP")" = "$(jq "[.check_runs[].name] | unique | length" "$RP/check-runs.json")" ]'
check "success and skipped conclusions are both SUCCESSFUL" '[ "$(jq "[.statuses[] | select(.state != \"SUCCESSFUL\")] | length" "$SNAP")" = 0 ]'
check "only the approving reviewer counts, comment-only reviews do not" '[ "$(jq -c ".participants | keys" "$SNAP")" = "[\"babakks\"]" ] && [ "$(jq -r ".participants.babakks.state" "$SNAP")" = approved ]'
check "inline review comments are keyed by id with their path and line" '[ "$(jq ".comments | length" "$SNAP")" = 2 ] && [ "$(jq -r ".comments[\"4405206188\"].line" "$SNAP")" = 15 ]'
check "no comment body reaches the snapshot" '! grep -q "$(jq -r ".[0].body" "$RP/review-comments.json" | cut -c1-20)" "$SNAP"'

summary
