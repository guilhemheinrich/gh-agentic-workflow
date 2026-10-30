#!/usr/bin/env bash
# snapshot.test.sh — bb_get error classes and the normalised PR snapshot.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
lib() { bash -c ". '$SKILL_DIR/scripts/lib/config.sh'; . '$SKILL_DIR/scripts/lib/api.sh'; . '$SKILL_DIR/scripts/lib/snapshot.sh'; $1"; }

export BBW_NOW=1793372646
fx_pr OPEN abc123 def456 "[$(fx_participant acc-1 'Julien Boutet' true approved), $(fx_participant acc-2 'Bot' false '')]"
fx_statuses abc123 '[{"key":"pr-analysis","name":"PR analysis","state":"INPROGRESS"}]'
fx_comments "[$(fx_comment 4521 'Julien Boutet' src/a.ts 42), $(fx_comment 4522 'Guilhem Heinrich' '' '' true)]"
fx_diffstat true

lib "snapshot_fetch $FX_REPO $FX_PR" >"$WORK/snap.json"; rc=$?
check "snapshot_fetch succeeds" '[ "$rc" = 0 ]' "rc=$rc"
expected='{"repo":"septeo-immobilier/modelo-bill-e","pr":229,"state":"OPEN","head":"abc123","dest_head":"def456",
 "title":"Cockpit cascade filters","url":"https://bitbucket.org/septeo-immobilier/modelo-bill-e/pull-requests/229",
 "participants":{"acc-1":{"name":"Julien Boutet","state":"approved"}},
 "statuses":{"pr-analysis":{"name":"PR analysis","state":"INPROGRESS"}},
 "comments":{"4521":{"author":"Julien Boutet","path":"src/a.ts","line":42,"deleted":false},
             "4522":{"author":"Guilhem Heinrich","path":null,"line":null,"deleted":true}},
 "conflict":true}'
check "snapshot has the normalised shape" '[ "$(jq -S "del(.fetched_at)" "$WORK/snap.json")" = "$(printf "%s" "$expected" | jq -S .)" ]' "$(cat "$WORK/snap.json")"
check "fetched_at is ISO UTC" 'jq -e ".fetched_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\")" "$WORK/snap.json" >/dev/null'

# Same heads as the previous snapshot: no diffstat call, conflict copied.
: >"$FAKE_CURL_LOG"
lib "snapshot_fetch $FX_REPO $FX_PR '$WORK/snap.json'" >"$WORK/snap2.json"
check "unchanged heads skip the diffstat call" '! grep -q diffstat "$FAKE_CURL_LOG"' "$(cat "$FAKE_CURL_LOG")"
check "unchanged heads copy the conflict flag" '[ "$(jq .conflict "$WORK/snap2.json")" = true ]'

# Moved head: diffstat is fetched again.
jq '.head = "zzz999"' "$WORK/snap.json" >"$WORK/prev-moved.json"
: >"$FAKE_CURL_LOG"
lib "snapshot_fetch $FX_REPO $FX_PR '$WORK/prev-moved.json'" >/dev/null
check "moved head fetches the diffstat" 'grep -q diffstat "$FAKE_CURL_LOG"'

# Two pages of comments: 60 ids.
p1="[$(for i in $(seq 1 50); do fx_comment "$((1000 + i))" Rev; [ "$i" -lt 50 ] && printf ','; done)]"
p2="[$(for i in $(seq 51 60); do fx_comment "$((1000 + i))" Rev; [ "$i" -lt 60 ] && printf ','; done)]"
fx_comments "$p1" 2
fx_comments "$p2" "" 2
n="$(lib "snapshot_fetch $FX_REPO $FX_PR" | jq '.comments | length')"
check "comments follow the next link (60 ids)" '[ "$n" = 60 ]' "n=$n"

# Error classes.
fx_put "repositories/$FX_REPO/pullrequests/$FX_PR" '{}' 401
lib "snapshot_fetch $FX_REPO $FX_PR" >/dev/null 2>&1; rc=$?
check "401 returns 10" '[ "$rc" = 10 ]' "rc=$rc"
fx_put "repositories/$FX_REPO/pullrequests/$FX_PR" '{}' 429
k="$(fixture_key "repositories/$FX_REPO/pullrequests/$FX_PR")"
printf 'Retry-After: 1\r\n' >"$FX/$k.headers"
BBW_RETRY_SLEEP=0 lib "bb_get repositories/$FX_REPO/pullrequests/$FX_PR" >/dev/null 2>&1; rc=$?
check "persistent 429 returns 12 after one retry" '[ "$rc" = 12 ] && [ "$(grep -c "pullrequests/229$" "$FAKE_CURL_LOG")" -ge 2 ]' "rc=$rc"
check "the token never appears in a request" '! grep -q SECRET "$FAKE_CURL_LOG"'

summary
