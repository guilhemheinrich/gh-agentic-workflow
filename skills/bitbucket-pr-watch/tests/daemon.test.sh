#!/usr/bin/env bash
# daemon.test.sh — poll cycle, settle window, urgent release, shared fetch,
# closing, auth errors, single instance.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
export BBW_SETTLE_SECONDS=30
T0=1793372000
SUBS="$BBW_STATE_DIR/subscriptions.json"
lib() { bash -c "for l in '$SKILL_DIR'/scripts/lib/*.sh; do . \"\$l\"; done; $1"; }
cycle() { BBW_NOW="$1" "$BBW" daemon once; }
unread() { lib "events_unread $1" | wc -l | tr -d ' '; }

fx_default
"$BBW" subscribe "$FX_REPO" 229 --session s1 --head ownhead000 >/dev/null
cycle "$T0"
check "baseline cycle releases nothing" '[ "$(unread s1)" = 0 ]'
check "baseline cycle writes the snapshot" '[ -f "$BBW_STATE_DIR/snapshots/septeo-immobilier__modelo-bill-e__229.json" ]'
check "cycle writes the heartbeat" '[ "$(cat "$BBW_STATE_DIR/heartbeat")" = "$T0" ]'

fx_comments "[$(fx_comment 4521 'Julien Boutet' src/a.ts 42)]"
cycle $((T0 + 10))
fx_statuses abc123 '[{"key":"pr-analysis","name":"PR analysis","state":"SUCCESSFUL"}]'
cycle $((T0 + 20))
fx_pr OPEN abc123 def456 "[$(fx_participant acc-1 'Julien Boutet' true approved)]"
cycle $((T0 + 30))
cycle $((T0 + 59))
check "nothing released inside the settle window" '[ "$(unread s1)" = 0 ]'
cycle $((T0 + 60))
check "three transitions released together after 30 s of quiet" '[ "$(unread s1)" = 3 ]' "$(lib "events_unread s1")"
lib 'events_ack s1 3'

fx_statuses abc123 '[{"key":"pr-analysis","name":"PR analysis","state":"FAILED"}]'
cycle $((T0 + 70))
check "a failure is released in the same cycle" '[ "$(unread s1)" = 1 ] && lib "events_unread s1" | grep -q FAILED'
lib 'events_ack s1 1'

fx_statuses abc123 '[{"key":"pr-analysis","name":"PR analysis","state":"INPROGRESS"}]'
cycle $((T0 + 80))
check "a running pipeline wakes nobody" '[ "$(unread s1)" = 0 ]'
check "the running pipeline is logged" 'grep -q "INPROGRESS" "$BBW_STATE_DIR/daemon.log"'

"$BBW" subscribe "$FX_REPO" 229 --session s2 >/dev/null
: >"$FAKE_CURL_LOG"
fx_pr MERGED abc123 def456 "[$(fx_participant acc-1 'Julien Boutet' true approved)]"
cycle $((T0 + 90))
check "two sessions on one PR share one fetch" '[ "$(grep -c "pullrequests/229$" "$FAKE_CURL_LOG")" = 1 ]' "$(cat "$FAKE_CURL_LOG")"
check "merge is released at once to s1" 'lib "events_unread s1" | grep -q "modelo-bill-e#229 merged"'
check "merge is released at once to s2" 'lib "events_unread s2" | grep -q "modelo-bill-e#229 merged"'
check "merge closes both subscriptions" '[ "$(jq "[.[] | select(.status != \"closed\")] | length" "$SUBS")" = 0 ]'

: >"$FAKE_CURL_LOG"
cycle $((T0 + 100))
check "closed subscriptions are not polled" '[ ! -s "$FAKE_CURL_LOG" ]'

# Pending subscription resolved by the daemon, then given up after 24 h.
q='repositories/septeo-immobilier/modelo-bill-e/pullrequests?q=source.branch.name%3D%22feat%2Fx%22%20AND%20state%3D%22OPEN%22'
fx_put "$q" '{"values":[]}'
BBW_NOW=$((T0 + 100)) "$BBW" subscribe --branch feat/x --repo "$FX_REPO" --session s3 >/dev/null
fx_put "$q" '{"values":[{"id":229}]}'
fx_default
cycle $((T0 + 110))
check "the daemon resolves a pending subscription" '"$BBW" list --session s3 | grep -q "#229 open"' "$("$BBW" list --session s3)"
fx_put "$q" '{"values":[]}'
BBW_NOW=$((T0 + 120)) "$BBW" subscribe --branch feat/x --repo "$FX_REPO" --session s4 >/dev/null
cycle $((T0 + 120 + 86401))
check "a pending subscription is dropped after 24 h" '[ -z "$("$BBW" list --session s4)" ]'

# Rejected credential.
fx_put "repositories/$FX_REPO/pullrequests/$FX_PR" '{}' 401
before="$(unread s3)"
cycle $((T0 + 200000))
check "a rejected credential is logged" 'grep -q "auth error: credential rejected" "$BBW_STATE_DIR/daemon.log"'
check "a rejected credential wakes nobody" '[ "$(unread s3)" = "$before" ]'

# Single instance.
sleep 30 & live=$!
printf '%s\n' "$live" >"$BBW_STATE_DIR/daemon.pid"
out="$("$BBW" daemon run 2>&1)"; rc=$?
kill "$live" 2>/dev/null
check "a second daemon refuses to start" '[ "$rc" = 1 ] && [ "$out" = "already running (pid $live)" ]' "rc=$rc $out"

# doctor sees the heartbeat.
export BBW_POLL_SECONDS=60
printf '%s\n' "$(date -u +%s)" >"$BBW_STATE_DIR/heartbeat"
check "doctor reports a live daemon" 'lib "daemon_alive"'
printf '%s\n' "$(( $(date -u +%s) - 1000 ))" >"$BBW_STATE_DIR/heartbeat"
check "doctor reports a stale daemon" '! lib "daemon_alive"'

summary
