#!/usr/bin/env bash
# wait.test.sh — delivery, blocking, exit codes 0/2/3, status output.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
export BBW_WAIT_POLL=1
lib() { bash -c "for l in '$SKILL_DIR'/scripts/lib/*.sh; do . \"\$l\"; done; $1"; }

"$BBW" subscribe "$FX_REPO" 229 --session s1 >/dev/null
( sleep 2; lib 'events_append s1 "{\"ts\":1,\"text\":\"modelo-bill-e#229 merged\"}"' ) &
start="$(date +%s)"
out="$("$BBW" wait --session s1)"; rc=$?
took=$(( $(date +%s) - start ))
check "wait prints the event text" '[ "$out" = "modelo-bill-e#229 merged" ]' "$out"
check "wait exits 0 on delivery" '[ "$rc" = 0 ]' "rc=$rc"
check "wait returns within 5 s" '[ "$took" -le 5 ]' "took=$took"

"$BBW" wait --session s1 >"$WORK/w2" 2>&1 & wpid=$!
sleep 3
if kill -0 "$wpid" 2>/dev/null; then ok "a second wait blocks"; kill "$wpid"; else nok "a second wait blocks" "$(cat "$WORK/w2")"; fi
wait "$wpid" 2>/dev/null

out="$("$BBW" wait --session s1 --timeout 1)"; rc=$?
check "--timeout exits 2 with nothing" '[ "$rc" = 2 ] && [ -z "$out" ]' "rc=$rc $out"

# Closed subscription with one unread event: deliver first, then exit 3.
jq 'map(.status = "closed")' "$BBW_STATE_DIR/subscriptions.json" >"$WORK/s" && cat "$WORK/s" >"$BBW_STATE_DIR/subscriptions.json"
lib 'events_append s1 "{\"ts\":2,\"text\":\"late line\"}"'
out="$("$BBW" wait --session s1)"; rc=$?
check "closed subscription still delivers its unread line" '[ "$rc" = 0 ] && [ "$out" = "late line" ]' "rc=$rc $out"
out="$("$BBW" wait --session s1 2>&1)"; rc=$?
check "then wait exits 3" '[ "$rc" = 3 ] && [ "$out" = "no open subscription" ]' "rc=$rc $out"

# A queued (not yet released) line keeps wait alive even without subscription.
mkdir -p "$BBW_STATE_DIR/pending"
printf '{"ts":3,"urgent":false,"text":"queued"}\n' >"$BBW_STATE_DIR/pending/s1.jsonl"
out="$("$BBW" wait --session s1 --timeout 1)"; rc=$?
check "a queued line makes wait wait, not exit 3" '[ "$rc" = 2 ]' "rc=$rc $out"
rm -f "$BBW_STATE_DIR/pending/s1.jsonl"

# status reads the last snapshot, no API call.
"$BBW" subscribe "$FX_REPO" 229 --session s5 >/dev/null
mkdir -p "$BBW_STATE_DIR/snapshots"
jq -n '{repo:"septeo-immobilier/modelo-bill-e",pr:229,state:"OPEN",head:"abc123",dest_head:"d",title:"Cockpit",url:"u",
  participants:{"a":{name:"Julien Boutet",state:"approved"}},statuses:{"k":{name:"PR analysis",state:"FAILED"}},
  comments:{"1":{author:"x",path:null,line:null,deleted:false},"2":{author:"y",path:null,line:null,deleted:true}},
  conflict:false,fetched_at:"2026-10-30T15:04:06Z"}' >"$BBW_STATE_DIR/snapshots/septeo-immobilier__modelo-bill-e__229.json"
: >"$FAKE_CURL_LOG"
out="$("$BBW" status "$FX_REPO" 229)"
check "status names state, pipeline, reviews and comments" '[ "$out" = "modelo-bill-e#229 OPEN · PR analysis FAILED · approved by Julien Boutet · 1 comment · conflict no · as of 2026-10-30T15:04:06Z" ]' "$out"
check "status makes no API call" '[ ! -s "$FAKE_CURL_LOG" ]'
out="$("$BBW" status --session s5)"
check "status --session lists the session PRs" 'printf "%s" "$out" | grep -q "^modelo-bill-e#229 OPEN"' "$out"

summary
