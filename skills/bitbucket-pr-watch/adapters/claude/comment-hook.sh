#!/usr/bin/env bash
# comment-hook.sh — Claude Code PostToolUse hook
# (matcher: mcp__bitbucket__add_pull_request_comment).
#
# The agent and the human share one Bitbucket account, so a comment cannot be
# told apart by author. This hook records the id of each comment the agent
# posts, so the daemon never wakes the session for its own words.
# Silent, exit 0 always. BBW_HOOKS=0 disables it.
set -uo pipefail
[ "${BBW_HOOKS:-1}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/find-bbw.sh" 2>/dev/null \
  || . "$HOME/.agents/hooks/bitbucket-pr-watch-find-bbw.sh" 2>/dev/null || exit 0
find_bbw || exit 0

payload="$(cat)"
session="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
slug="$(printf '%s' "$payload" | jq -r '.tool_input.repository_name // empty')"
pr="$(printf '%s' "$payload" | jq -r '.tool_input.pull_request_id // empty | tostring')"
# The created comment's id, wherever the MCP server put it: a JSON object, or
# JSON text inside a content block.
id="$(printf '%s' "$payload" | jq -r '
  [.tool_response | .. | (objects | .id? // empty),
                         (strings | (try fromjson catch null) | objects? | .id? // empty)]
  | map(select(type == "number")) | first // empty')"
[ -n "$session" ] && [ -n "$slug" ] && [ -n "$pr" ] && [ -n "$id" ] || exit 0

repo="$(bash "$BBW" list --session "$session" 2>/dev/null \
  | awk -v s="/$slug#$pr" 'index($1, s) && substr($1, length($1) - length(s) + 1) == s { sub(/#.*/, "", $1); print $1; exit }')"
[ -n "$repo" ] || exit 0
bash "$BBW" ignore-comment "$repo" "$pr" "$id" --session "$session" >/dev/null 2>&1
exit 0
