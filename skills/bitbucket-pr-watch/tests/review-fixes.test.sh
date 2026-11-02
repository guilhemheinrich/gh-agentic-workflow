#!/usr/bin/env bash
# review-fixes.test.sh — regressions found by the final branch review.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
export BBW_WAIT_POLL=1
lib() { bash -c "for l in '$SKILL_DIR'/scripts/lib/*.sh; do . \"\$l\"; done; $1"; }
SUBS="$BBW_STATE_DIR/subscriptions.json"

# 1. Two concurrent waits: one delivery, the second exits 4, nothing lost.
"$BBW" subscribe "$FX_REPO" 229 --session dup >/dev/null
"$BBW" wait --session dup >"$WORK/w1" 2>&1 & p1=$!
sleep 1
"$BBW" wait --session dup --timeout 2 >"$WORK/w2" 2>&1; rc2=$?
check "a second wait for the same session exits 4 at once" '[ "$rc2" = 4 ] && grep -q "already waiting" "$WORK/w2"' "rc=$rc2 $(cat "$WORK/w2")"
lib 'events_append dup "{\"ts\":1,\"text\":\"line1\"}"'
wait "$p1"
check "the first wait delivers the line" '[ "$(cat "$WORK/w1")" = line1 ]' "$(cat "$WORK/w1")"
lib 'events_append dup "{\"ts\":2,\"text\":\"line2\"}"'
out="$("$BBW" wait --session dup --timeout 3)"
check "the next line is still delivered" '[ "$out" = line2 ]' "$out"

# 2. Release lands between wait's read and its subscription check: no exit 3.
"$BBW" subscribe "$FX_REPO" 229 --session race >/dev/null
jq 'map(if .session == "race" then .status = "closed" else . end)' "$SUBS" >"$WORK/s" && cat "$WORK/s" >"$SUBS"
out="$(bash -c "for l in '$SKILL_DIR'/scripts/lib/*.sh; do . \"\$l\"; done
  real_unread=\$(declare -f events_unread | sed '1s/events_unread/real_events_unread/'); eval \"\$real_unread\"
  events_unread() { if [ ! -f '$WORK/raced' ]; then touch '$WORK/raced'; events_append race '{\"ts\":3,\"text\":\"merged\"}'; return 0; fi; real_events_unread \"\$@\"; }
  cmd_wait --session race")"; rc=$?
check "a line released during the check is delivered, not exit 3" '[ "$rc" = 0 ] && [ "$out" = merged ]' "rc=$rc $out"

# 3. A 403 on one repo does not starve the others; pending auth failures are logged.
fx_default
FX_REPO_SAVE="$FX_REPO"
FX_REPO="aaa-other/private"; fx_put "repositories/$FX_REPO/pullrequests/$FX_PR" '{}' 403
FX_REPO="$FX_REPO_SAVE"
"$BBW" subscribe aaa-other/private 229 --session s403 >/dev/null
"$BBW" subscribe "$FX_REPO" 229 --session s403 >/dev/null
: >"$FAKE_CURL_LOG"
BBW_NOW=1793372000 "$BBW" daemon once
check "a 403 repo is logged as no access" 'grep -q "no access to aaa-other/private#229 (403)" "$BBW_STATE_DIR/daemon.log"'
check "the next repo is still polled" 'grep -q "modelo-bill-e/pullrequests/229$" "$FAKE_CURL_LOG"' "$(cat "$FAKE_CURL_LOG")"
fx_put "$(printf 'repositories/%s/user' x)" '{}'
q='repositories/septeo-immobilier/modelo-bill-e/pullrequests?q=source.branch.name%3D%22feat%2Fauth%22%20AND%20state%3D%22OPEN%22'
fx_put "$q" '{"values":[]}'
BBW_NOW=1793372000 "$BBW" subscribe --branch feat/auth --repo "$FX_REPO" --session sauth >/dev/null
fx_put "$q" '{}' 401
: >"$BBW_STATE_DIR/daemon.log"
BBW_NOW=1793372100 "$BBW" daemon once
check "a rejected credential while resolving a pending branch is logged" 'grep -q "auth error: credential rejected" "$BBW_STATE_DIR/daemon.log"' "$(cat "$BBW_STATE_DIR/daemon.log")"

# 4. Same failing status on a new head wakes.
URL="u"
jq -n '{repo:"w/r",pr:1,state:"OPEN",head:"aaaaaaaaaaaa",dest_head:"d",title:"t",url:"u",participants:{},
  statuses:{"build":{name:"build",state:"FAILED"}},comments:{},conflict:false,fetched_at:"x"}' >"$WORK/o.json"
jq '.head = "bbbbbbbbbbbb"' "$WORK/o.json" >"$WORK/n.json"
out="$(lib "diff_snapshots '$WORK/o.json' '$WORK/n.json' '{\"own_heads\":[\"bbbbbbbbbbbb0000\"],\"ignored_comments\":[]}'")"
check "a FAILED status on a new own head wakes" 'printf "%s" "$out" | jq -e "select(.kind == \"status\" and .wake and .urgent)" >/dev/null' "$out"

# 5. Uninstall survives prompt hooks and a missing hooks key.
mkdir -p "$HOME/.claude"
S="$HOME/.claude/settings.json"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"prompt","prompt":"x"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.agents/hooks/bitbucket-pr-watch-push.sh"}]}]}}' >"$S"
mkdir -p "$HOME/.agents/hooks"; touch "$HOME/.agents/hooks/bitbucket-pr-watch-push.sh"
out="$("$BBW" uninstall --claude 2>&1)"; rc=$?
check "uninstall removes our entry next to a prompt hook" '[ "$rc" = 0 ] && [ "$(jq "[.. | .command? // empty | select(test(\"bitbucket-pr-watch\"))] | length" "$S")" = 0 ] && jq -e ".hooks.Stop[0].hooks[0].type == \"prompt\"" "$S" >/dev/null' "rc=$rc $out $(cat "$S")"
printf '{"model":"x"}\n' >"$S"
out="$("$BBW" uninstall --claude 2>&1)"; rc=$?
check "uninstall without a hooks key is clean" '[ "$rc" = 0 ] && ! printf "%s" "$out" | grep -qi error && [ "$(jq -c . "$S")" = "{\"model\":\"x\"}" ]' "rc=$rc $out"

# 6. A pidfile naming a live process that is not bbw does not block the daemon.
check "a reused pid is not taken for the daemon" '! lib "sleep 30 & daemon_pid_is_ours \$!; r=\$?; kill \$!; exit \$r"'
printf 'sleep 30\n' >"$WORK/fakebbw"
check "a real daemon pid is recognised" 'lib "bash \"$WORK/fakebbw\" daemon run & sleep 0.3; daemon_pid_is_ours \$!; r=\$?; kill \$!; exit \$r"'

# 7. The SessionStart hook makes no network call and checks only the heartbeat.
date -u +%s >"$BBW_STATE_DIR/heartbeat"
: >"$FAKE_CURL_LOG"
jq -cn '{session_id:"nobody", cwd:"/", hook_event_name:"SessionStart", source:"startup"}' \
  | BBW_BIN="$BBW" bash "$SKILL_DIR/adapters/claude/session-start-hook.sh" >/dev/null
check "session start makes no API call" '[ ! -s "$FAKE_CURL_LOG" ]' "$(cat "$FAKE_CURL_LOG")"
check "the SessionStart entry skips compact and clear" '[ "$(jq -r ".hooks.SessionStart[0].matcher" "$SKILL_DIR/adapters/claude/settings-snippet.json")" = "startup|resume" ]'

# 8. bbw reached through a symlink still finds its libraries.
ln -s "$BBW" "$WORK/bin/bbw"
out="$("$WORK/bin/bbw" list 2>&1)"; rc=$?
check "bbw works through a symlink" '[ "$rc" = 0 ] && ! printf "%s" "$out" | grep -q "unknown command"' "rc=$rc $out"

summary
