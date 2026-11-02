#!/usr/bin/env bash
# pipelines.test.sh — the build phase: the merge commit of a merged PR and a
# pushed commit followed until their pipelines end; fetch-error accounting
# and doctor's subscription health; the daemon re-exec on stale scripts.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
export BBW_SETTLE_SECONDS=30 BBW_WAIT_POLL=1
T0=1793372000
lib() { bash -c "for l in '$SKILL_DIR'/scripts/lib/*.sh; do . \"\$l\"; done; $1"; }
cycle() { BBW_NOW="$1" "$BBW" daemon once; }
unread() { lib "events_unread $1" | jq -r .text; }
# fresh — a new state dir per scenario.
n=0
fresh() { n=$((n + 1)); export BBW_STATE_DIR="$WORK/state $n"; SUBS="$BBW_STATE_DIR/subscriptions.json"; }

# 1. Merge, then a FAILED staging pipeline: one urgent wake, then exit 3.
fresh
fx_default
"$BBW" subscribe "$FX_REPO" 229 --session s1 >/dev/null
cycle "$T0"
fx_pr MERGED abc123 def456 '[]' mrg111
fx_statuses mrg111 '[]'
cycle $((T0 + 10))
check "merge wakes with the merged line" 'unread s1 | grep -q "modelo-bill-e#229 merged"'
lib 'events_ack s1 1'
check "the subscription follows the merge commit" 'grep -q "modelo-bill-e#229 build staging@mrg111 s1" <<<"$("$BBW" list --session s1)"' "$("$BBW" list --session s1)"
out="$("$BBW" wait --session s1 --timeout 1)"; rc=$?
check "wait keeps waiting during the build phase (exit 2, not 3)" '[ "$rc" = 2 ]' "rc=$rc $out"
check "the merge is logged with its commit and branch" 'grep -q "MERGED — following merge commit mrg111 on staging" "$BBW_STATE_DIR/daemon.log"'
fx_statuses mrg111 '[{"key":"p1","name":"Pipeline staging","state":"INPROGRESS","url":"https://bitbucket.org/x/pipelines/812"},
                     {"key":"sonar","name":"Sonar","state":"SUCCESSFUL","url":"https://sonar/x"}]'
cycle $((T0 + 20))
check "a running merge pipeline wakes nobody" '[ -z "$(unread s1)" ]'
check "a running merge pipeline turns the fast poll on" 'lib daemon_any_running'
check "status shows the followed commit" 'grep -q "^modelo-bill-e@mrg111 build · Pipeline staging INPROGRESS, Sonar SUCCESSFUL" <<<"$("$BBW" status --session s1)"' "$("$BBW" status --session s1)"
fx_statuses mrg111 '[{"key":"p1","name":"Pipeline staging","state":"FAILED","url":"https://bitbucket.org/x/pipelines/812"},
                     {"key":"sonar","name":"Sonar","state":"SUCCESSFUL","url":"https://sonar/x"}]'
cycle $((T0 + 30))
out="$(unread s1)"
check "the failed merge pipeline wakes once, at once, with its link" '[ "$out" = "modelo-bill-e#229 after merge into staging @mrg111: \"Pipeline staging\" FAILED, \"Sonar\" SUCCESSFUL · https://bitbucket.org/x/pipelines/812" ]' "$out"
check "the build phase is closed" '[ "$(jq -r ".[0].status" "$SUBS")" = closed ]'
check "the build snapshot is dropped once nobody follows it" '! ls "$BBW_STATE_DIR/snapshots" | grep -q commit-mrg111'
lib 'events_ack s1 1'
out="$("$BBW" wait --session s1 --timeout 1)"; rc=$?
check "after the build phase wait exits 3" '[ "$rc" = 3 ]' "rc=$rc $out"

# 2. A branch without pipeline: closed after BBW_BUILD_FIRST_SECONDS.
fresh
fx_default
"$BBW" subscribe "$FX_REPO" 229 --session s2 >/dev/null
cycle "$T0"
fx_pr MERGED abc123 def456 '[]' mrg222
fx_statuses mrg222 '[]'
cycle $((T0 + 10))
lib 'events_ack s2 1'
cycle $((T0 + 10 + 899))
check "no wake before the no-pipeline timeout" '[ -z "$(unread s2)" ]'
cycle $((T0 + 10 + 900))
check "no pipeline in 15 min wakes once and closes" 'unread s2 | grep -q "@mrg222: no pipeline reported within 15 min — watch closed"' "$(unread s2)"
check "and the subscription is closed" '[ "$(jq -r ".[0].status" "$SUBS")" = closed ]'

# 3. Fast-forward merge: the merge commit is the PR head, whose finished PR
#    pipeline must not pass for the branch pipeline.
fresh
fx_pr OPEN fff333 def456 '[]'
fx_statuses fff333 '[{"key":"pr","name":"PR analysis","state":"SUCCESSFUL","updated_on":"2026-11-02T10:00:00Z"}]'
"$BBW" subscribe "$FX_REPO" 229 --session s3 >/dev/null
cycle "$T0"
fx_pr MERGED fff333 def456 '[]' fff333
cycle $((T0 + 10))
lib 'events_ack s3 1'
cycle $((T0 + 20))
check "the finished PR pipeline on a fast-forwarded head does not end the phase" '[ -z "$(unread s3)" ] && [ "$(jq -r ".[0].status" "$SUBS")" = build ]' "$(unread s3)"
fx_statuses fff333 '[{"key":"pr","name":"PR analysis","state":"SUCCESSFUL","updated_on":"2026-11-02T10:00:00Z"},
                     {"key":"br","name":"Pipeline staging","state":"SUCCESSFUL","updated_on":"2026-11-02T10:09:00Z"}]'
cycle $((T0 + 30))
check "the branch pipeline on the same commit ends it" '[ "$(unread s3)" = "modelo-bill-e#229 after merge into staging @fff333: \"Pipeline staging\" SUCCESSFUL" ]' "$(unread s3)"

# 4. MERGED without merge_commit yet: asked again on the next cycle.
fresh
fx_default
"$BBW" subscribe "$FX_REPO" 229 --session s4 >/dev/null
cycle "$T0"
fx_pr MERGED abc123 def456 '[]'
cycle $((T0 + 10))
check "an unknown merge commit stays in the build phase" '[ "$(jq -r ".[0].status + \" \" + (.[0].commit // \"null\")" "$SUBS")" = "build null" ]' "$(cat "$SUBS")"
fx_pr MERGED abc123 def456 '[]' mrg444
fx_statuses mrg444 '[{"key":"b","name":"Pipeline staging","state":"SUCCESSFUL"}]'
cycle $((T0 + 20))
check "the merge commit is filled in later and followed" 'unread s4 | grep -q "@mrg444: \"Pipeline staging\" SUCCESSFUL"' "$(unread s4) $(cat "$SUBS")"

# 5. A pushed commit without PR (direct push to staging).
fresh
"$BBW" subscribe --commit c0ffee12 --branch staging --repo "$FX_REPO" --session s5 >/dev/null
q='repositories/septeo-immobilier/modelo-bill-e/pullrequests?q=source.branch.name%3D%22staging%22%20AND%20state%3D%22OPEN%22'
fx_put "$q" '{"values":[]}'
"$BBW" subscribe --branch staging --repo "$FX_REPO" --session s5 >/dev/null
check "a commit subscription and a pending branch coexist" '[ "$("$BBW" list --session s5 | wc -l | tr -d " ")" = 2 ]' "$("$BBW" list --session s5)"
check "the commit subscription is listed" 'grep -q "^septeo-immobilier/modelo-bill-e build staging@c0ffee12 s5" <<<"$("$BBW" list --session s5)"' "$("$BBW" list --session s5)"
FX_REPO_S="$FX_REPO"
fx_statuses c0ffee12 '[{"key":"b","name":"Pipeline staging","state":"INPROGRESS"}]'
cycle "$T0"
fx_statuses c0ffee12 '[{"key":"b","name":"Pipeline staging","state":"STOPPED"}]'
cycle $((T0 + 10))
check "a stopped pipeline on a pushed commit wakes" '[ "$(unread s5)" = "modelo-bill-e push to staging @c0ffee1: \"Pipeline staging\" STOPPED" ]' "$(unread s5)"
check "the pending branch subscription survives" 'grep -q "@staging pending" <<<"$("$BBW" list --session s5)"'
"$BBW" subscribe --commit deadbeef --repo "$FX_REPO" --session s5 >/dev/null
"$BBW" unsubscribe "$FX_REPO" --commit deadbeef --session s5
check "unsubscribe --commit removes it" '! "$BBW" list --session s5 | grep -q deadbeef'
out="$("$BBW" subscribe --commit 'x;rm' --repo "$FX_REPO" --session s5 2>&1)"; rc=$?
check "a non-hex commit is refused" '[ "$rc" = 64 ]' "rc=$rc $out"

# 6. Fetch errors carry the HTTP code; doctor flags them and a missing snapshot.
fresh
fx_default
printf '{"display_name":"Dev"}' >"$FX/user.json"
dk="$(fixture_key "repositories/$FX_REPO/pullrequests/$FX_PR/diffstat?pagelen=500")"
printf 302 >"$FX/$dk.code"
"$BBW" subscribe "$FX_REPO" 229 --session s6 >/dev/null
for i in 0 1 2; do cycle $((T0 + i * 60)); done
check "a code 13 is logged with its HTTP code and URL" 'grep -q "fetch error septeo-immobilier/modelo-bill-e#229 (code 13, HTTP 302 on repositories/septeo-immobilier/modelo-bill-e/pullrequests/229/diffstat?pagelen=500)" "$BBW_STATE_DIR/daemon.log"' "$(cat "$BBW_STATE_DIR/daemon.log")"
date -u +%s >"$BBW_STATE_DIR/heartbeat"
out="$("$BBW" doctor 2>&1)"; rc=$?
check "doctor flags repeated fetch errors" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "^FAIL septeo-immobilier/modelo-bill-e 229: 3 consecutive fetch errors (code 13, HTTP 302 on repositories/.*/diffstat?pagelen=500)"' "rc=$rc $out"
check "doctor never prints the token" '! printf "%s" "$out" | grep -q SECRET'
rm -f "$FX/$dk.code"
cycle $((T0 + 200))
date -u +%s >"$BBW_STATE_DIR/heartbeat"
out="$("$BBW" doctor 2>&1)"; rc=$?
check "a successful fetch clears the error count" '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "^ok subscriptions fetched"' "rc=$rc $out"
FX_PR=230; fx_pr OPEN abc123 def456 '[]'; FX_PR=229
BBW_NOW=$(( $(date -u +%s) - 600 )) "$BBW" subscribe "$FX_REPO" 230 --session s6 >/dev/null
out="$("$BBW" doctor 2>&1)"; rc=$?
check "doctor flags a subscription never snapshotted" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "^FAIL septeo-immobilier/modelo-bill-e 230: no snapshot yet"' "rc=$rc $out"

# 7. The daemon re-execs itself when its scripts change on disk.
fresh
cp -R "$SKILL_DIR" "$WORK/copy"
rm -f "$BBW_STATE_DIR/daemon.pid"
mkdir -p "$BBW_STATE_DIR"
BBW_POLL_SECONDS=1 bash "$WORK/copy/scripts/bbw" daemon run >/dev/null 2>&1 & dpid=$!
sleep 1.5
printf '\ndaemon_log "reloaded-marker"\n' >>"$WORK/copy/scripts/lib/wait.sh"
for i in 1 2 3 4 5 6 7 8; do grep -q reloaded-marker "$BBW_STATE_DIR/daemon.log" 2>/dev/null && break; sleep 0.5; done
check "the daemon logs the re-exec with the changed file" 'grep -q "scripts changed on disk (.*/lib/wait.sh) — re-exec (pid $dpid)" "$BBW_STATE_DIR/daemon.log"' "$(cat "$BBW_STATE_DIR/daemon.log")"
check "the re-exec loads the new code" 'grep -q reloaded-marker "$BBW_STATE_DIR/daemon.log"'
check "the re-exec keeps the pid and the daemon runs on" 'kill -0 "$dpid" && [ "$(cat "$BBW_STATE_DIR/daemon.pid")" = "$dpid" ]'
check "the re-exec does not take itself for a second daemon" '! grep -q "already running" "$BBW_STATE_DIR/daemon.log"'
kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
# doctor: scripts changed long ago and the daemon never reloaded.
touch -d "@$(( $(date -u +%s) - 1000 ))" "$BBW_STATE_DIR/daemon.started"
touch -d "@$(( $(date -u +%s) - 500 ))" "$WORK/copy/scripts/lib/api.sh"
date -u +%s >"$BBW_STATE_DIR/heartbeat"
out="$(bash "$WORK/copy/scripts/bbw" doctor 2>&1)"; rc=$?
check "doctor flags a daemon running stale code" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "^FAIL daemon runs code older than .*/lib/api.sh"' "rc=$rc $out"

summary
