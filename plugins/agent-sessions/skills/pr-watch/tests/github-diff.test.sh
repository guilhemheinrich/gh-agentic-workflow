#!/usr/bin/env bash
# diff.test.sh — transitions between two snapshots, and which ones wake.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"
fx_pr_open

OLD="$WORK/old.json" NEW="$WORK/new.json"
lib "snapshot_fetch $FX_KEY $FX_PR >'$OLD'" 2>/dev/null
# Same head, lint finishes red and a new comment arrives.
jq '.statuses["check:lint"].state = "FAILED"
    | .comments["9003"] = {author: "dave", path: null, line: null, deleted: false}' "$OLD" >"$NEW"
SUB='{"repo":"octo-org/cockpit","pr":42,"session":"s1","own_heads":[],"ignored_comments":[]}'

out="$(lib "diff_snapshots '$OLD' '$NEW' '$SUB'")"
check "a failed check wakes urgently" 'printf "%s" "$out" | jq -e "select(.kind == \"status\" and .urgent == true)" >/dev/null' "$out"
check "a new comment wakes" 'printf "%s" "$out" | jq -e "select(.kind == \"comment\" and .wake == true)" >/dev/null' "$out"

# A commit pushed by this session never wakes it.
jq '.head = "ownhead000000000000000000000000000000000" | .statuses = .statuses' "$OLD" >"$WORK/old2.json"
jq '.head = "ownhead000000000000000000000000000000000"' "$NEW" >"$WORK/new2.json"
SUB2='{"repo":"octo-org/cockpit","pr":42,"session":"s1","own_heads":["ownhead000000000000000000000000000000000"],"ignored_comments":[]}'
out="$(lib "diff_snapshots '$WORK/old2.json' '$WORK/new2.json' '$SUB2'")"
check "own push does not wake" '! printf "%s" "$out" | jq -e "select(.kind == \"head\")" >/dev/null' "$out"

# A comment the session posted never wakes it.
jq '.comments["9004"] = {author: "me", path: null, line: null, deleted: false}' "$NEW" >"$WORK/new3.json"
SUB3='{"repo":"octo-org/cockpit","pr":42,"session":"s1","own_heads":[],"ignored_comments":["9004"]}'
out="$(lib "diff_snapshots '$OLD' '$WORK/new3.json' '$SUB3'")"
check "own comment does not wake" '! printf "%s" "$out" | jq -e "select(.kind == \"comment\" and (.text | test(\"9004\")))" >/dev/null' "$out"

# An approval wakes.
jq '.participants.dave = {name: "dave", state: "approved"}' "$OLD" >"$WORK/old4.json"
out="$(lib "diff_snapshots '$WORK/old4.json' '$OLD' '$SUB'")"
check "a withdrawn approval wakes" 'printf "%s" "$out" | jq -e "select(.kind == \"review\" and (.text | test(\"withdrew approval\")))" >/dev/null' "$out"

# A missing old snapshot is a baseline: nothing is printed.
out="$(lib "diff_snapshots '$WORK/none.json' '$NEW' '$SUB'")"
check "no previous snapshot is a silent baseline" '[ -z "$out" ]' "$out"

summary
