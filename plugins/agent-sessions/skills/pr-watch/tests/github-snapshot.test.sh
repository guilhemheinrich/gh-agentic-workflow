#!/usr/bin/env bash
# snapshot.test.sh — GitHub payloads reduced to wake-relevant fields.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"
fx_pr_open

SNAP="$WORK/snap.json"
lib "snapshot_fetch $FX_KEY $FX_PR >'$SNAP'" 2>/dev/null; rc=$?
check "snapshot fetch succeeds" '[ "$rc" = 0 ]' "rc=$rc"
check "PR is OPEN" '[ "$(jq -r .state "$SNAP")" = OPEN ]'
check "head and dest recorded" '[ "$(jq -r .head "$SNAP")" = "'"$FX_HEAD"'" ] && [ "$(jq -r .dest_branch "$SNAP")" = staging ]'
check "completed success check is SUCCESSFUL" '[ "$(jq -r ".statuses[\"check:build\"].state" "$SNAP")" = SUCCESSFUL ]'
check "running check is INPROGRESS" '[ "$(jq -r ".statuses[\"check:lint\"].state" "$SNAP")" = INPROGRESS ]'
check "legacy commit status is SUCCESSFUL" '[ "$(jq -r ".statuses[\"status:sonar\"].state" "$SNAP")" = SUCCESSFUL ]'
check "approval kept, comment-only review ignored" '[ "$(jq -r .participants.alice.state "$SNAP")" = approved ] && [ "$(jq -r ".participants | has(\"carol\")" "$SNAP")" = false ]'
check "change request kept" '[ "$(jq -r .participants.bob.state "$SNAP")" = changes_requested ]'
check "review and conversation comments keyed by id" '[ "$(jq -r ".comments[\"9001\"].path" "$SNAP")" = src/a.ts ] && [ "$(jq -r ".comments[\"9002\"].author" "$SNAP")" = carol ]'
check "clean PR has no conflict" '[ "$(jq -r .conflict "$SNAP")" = false ]'
check "comment bodies never reach the snapshot" '! grep -q "SECRET BODY\|another secret" "$SNAP"'

# A merged PR reports its merge commit and MERGED.
fx_put "repos/$FX_REPO/pulls/$FX_PR" '{"number": 42, "state": "closed", "merged": true,
  "title": "t", "html_url": "u", "head": {"sha": "'"$FX_HEAD"'"}, "base": {"sha": "b", "ref": "staging"},
  "merge_commit_sha": "'"$FX_MERGE"'", "mergeable": null}'
lib "snapshot_fetch $FX_KEY $FX_PR '$SNAP' >'$WORK/merged.json'" 2>/dev/null
check "merged PR is MERGED with its merge commit" '[ "$(jq -r .state "$WORK/merged.json")" = MERGED ] && [ "$(jq -r .merge_commit "$WORK/merged.json")" = "'"$FX_MERGE"'" ]'
check "unknown mergeability keeps the previous answer" '[ "$(jq -r .conflict "$WORK/merged.json")" = false ]'

# A dirty PR is a conflict.
fx_put "repos/$FX_REPO/pulls/$FX_PR" '{"number": 42, "state": "open", "merged": false, "title": "t", "html_url": "u",
  "head": {"sha": "'"$FX_HEAD"'"}, "base": {"sha": "b", "ref": "staging"}, "mergeable": false, "mergeable_state": "dirty"}'
lib "snapshot_fetch $FX_KEY $FX_PR >'$WORK/dirty.json'" 2>/dev/null
check "dirty PR reports a conflict" '[ "$(jq -r .conflict "$WORK/dirty.json")" = true ]'

# A 401 on the PR stops the fetch with code 10.
fx_put "repos/$FX_REPO/pulls/$FX_PR" '{}' 401
lib "snapshot_fetch $FX_KEY $FX_PR" >/dev/null 2>&1; rc=$?
check "rejected credential returns 10" '[ "$rc" = 10 ]' "rc=$rc"

summary
