#!/usr/bin/env bash
# claude-hooks.test.sh — the Claude adapter: push, own comment, session start,
# and the confirmed install into settings.json.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
AD="$SKILL_DIR/adapters/claude"
export BBW_BIN="$BBW"
SUBS="$BBW_STATE_DIR/subscriptions.json"

REPO="$WORK/repo"
git init -q -b feat/cascade "$REPO"
git -C "$REPO" config user.email t@example.test; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" remote add origin git@bitbucket.org:septeo-immobilier/modelo-bill-e.git
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
fx_put 'repositories/septeo-immobilier/modelo-bill-e/pullrequests?q=source.branch.name%3D%22feat%2Fcascade%22%20AND%20state%3D%22OPEN%22' '{"values":[{"id":229}]}'

payload() { # COMMAND
  jq -cn --arg c "$1" --arg cwd "$REPO" '{session_id:"sess-1", cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:"", stderr:""}}'
}

out="$(payload 'git push -u origin feat/cascade' | bash "$AD/push-hook.sh")"; rc=$?
check "push hook exits 0" '[ "$rc" = 0 ]'
check "push hook answers in the PostToolUse JSON shape" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.hookEventName == \"PostToolUse\"" >/dev/null' "$out"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
check "context names the subscribed PR" 'printf "%s" "$ctx" | grep -q "subscribed septeo-immobilier/modelo-bill-e#229"' "$ctx"
check "context tells the agent to start the wait" 'printf "%s" "$ctx" | grep -q "bbw wait --session sess-1" && printf "%s" "$ctx" | grep -q run_in_background' "$ctx"
check "the pushed head is recorded as own" '[ "$(jq -r ".[0].own_heads[0]" "$SUBS")" = "$HEAD_SHA" ]' "$(cat "$SUBS")"

out="$(payload 'git status' | bash "$AD/push-hook.sh")"
check "non-push commands are ignored" '[ -z "$out" ]' "$out"
out="$(payload 'git -C sub push origin x' | BBW_BIN=/nonexistent bash "$AD/push-hook.sh")"; rc=$?
check "push hook exits 0 silently when bbw is missing" '[ "$rc" = 0 ] && [ -z "$out" ]' "rc=$rc $out"

# Own comment through the Bitbucket MCP tool.
cpayload="$(jq -cn --arg cwd "$REPO" '{session_id:"sess-1", cwd:$cwd, hook_event_name:"PostToolUse",
  tool_name:"mcp__bitbucket__add_pull_request_comment",
  tool_input:{repository_name:"modelo-bill-e", pull_request_id:"229", content:"done"},
  tool_response:[{type:"text", text:"{\"id\": 4999, \"content\": {\"raw\": \"done\"}}"}]}')"
out="$(printf '%s' "$cpayload" | bash "$AD/comment-hook.sh")"; rc=$?
check "comment hook is silent and exits 0" '[ "$rc" = 0 ] && [ -z "$out" ]' "rc=$rc $out"
check "own comment id is ignored" '[ "$(jq -c ".[0].ignored_comments" "$SUBS")" = "[\"4999\"]" ]' "$(cat "$SUBS")"

# Session start.
spayload() { jq -cn --arg s "$1" --arg cwd "$REPO" '{session_id:$s, cwd:$cwd, hook_event_name:"SessionStart", source:"resume"}'; }
out="$(spayload sess-1 | bash "$AD/session-start-hook.sh")"; rc=$?
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
check "session start re-arms a subscribed session" '[ "$rc" = 0 ] && printf "%s" "$ctx" | grep -q "septeo-immobilier/modelo-bill-e#229" && printf "%s" "$ctx" | grep -q "bbw wait --session sess-1"' "rc=$rc $out"
out="$(spayload other | bash "$AD/session-start-hook.sh")"
check "session start is silent for an unsubscribed session" '[ -z "$out" ]' "$out"

# Install into settings.json, only on a yes.
mkdir -p "$HOME/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/x.sh"}]}]}}\n' >"$HOME/.claude/settings.json"
cp "$HOME/.claude/settings.json" "$WORK/settings.before"
printf 'me@x\ntok\n' | "$BBW" setup --non-interactive >/dev/null 2>&1
out="$(printf 'n\n' | "$BBW" setup --claude --non-interactive 2>&1)"
check "the install shows what it will add" 'printf "%s" "$out" | grep -q "bitbucket-pr-watch-push"' "$out"
check "answering n leaves settings.json byte-identical" 'cmp -s "$HOME/.claude/settings.json" "$WORK/settings.before"'
printf 'y\n' | "$BBW" setup --claude --non-interactive >/dev/null 2>&1
S="$HOME/.claude/settings.json"
check "yes registers the push hook" 'jq -e "[.hooks.PostToolUse[] | select(.matcher == \"Bash\") | .hooks[].command] | any(test(\"bitbucket-pr-watch-push\"))" "$S" >/dev/null' "$(cat "$S")"
check "yes registers the comment hook" 'jq -e "[.hooks.PostToolUse[] | select(.matcher == \"mcp__bitbucket__add_pull_request_comment\")] | length == 1" "$S" >/dev/null'
check "yes registers the session start hook" 'jq -e "[.hooks.SessionStart[].hooks[].command] | any(test(\"bitbucket-pr-watch-session-start\"))" "$S" >/dev/null'
check "existing hooks are kept" 'jq -e ".hooks.Stop[0].hooks[0].command == \"bash ~/x.sh\"" "$S" >/dev/null'
check "hook scripts are copied" '[ -f "$HOME/.agents/hooks/bitbucket-pr-watch-push.sh" ]'
printf 'y\n' | "$BBW" setup --claude --non-interactive >/dev/null 2>&1
check "a second install adds nothing" '[ "$(jq "[.. | .command? // empty | select(test(\"bitbucket-pr-watch\"))] | length" "$S")" = 3 ]' "$(cat "$S")"
out="$("$BBW" doctor 2>&1)"
check "doctor sees the wired hooks" 'printf "%s" "$out" | grep -q "^ok claude hooks"' "$out"
"$BBW" uninstall --claude >/dev/null
check "uninstall removes our hooks only" '[ "$(jq "[.. | .command? // empty | select(test(\"bitbucket-pr-watch\"))] | length" "$S")" = 0 ] && jq -e ".hooks.Stop[0].hooks[0].command == \"bash ~/x.sh\"" "$S" >/dev/null' "$(cat "$S")"

summary
