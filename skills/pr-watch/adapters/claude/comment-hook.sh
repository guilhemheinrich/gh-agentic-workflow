#!/usr/bin/env bash
# comment-hook.sh — Claude Code PostToolUse hook for the comments the agent
# posts. Two matchers call it:
#   mcp__bitbucket__add_pull_request_comment   Bitbucket Cloud, through the MCP
#   Bash                                       GitHub, when the command is
#                                              `gh pr comment` or `gh api`
#
# The agent and the human share one account on each host, so a comment cannot
# be told apart by author. This hook records the id of each comment the agent
# posts, so the daemon never wakes the session for its own words.
# Silent, exit 0 always. PRW_HOOKS=0 disables it.
set -uo pipefail
[ "${PRW_HOOKS:-1}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/find-prw.sh" 2>/dev/null \
  || . "$HOME/.agents/hooks/pr-watch-find-prw.sh" 2>/dev/null || exit 0
find_prw || exit 0

payload="$(cat)"
session="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ -n "$session" ] || exit 0

# bitbucket_comment — record the Bitbucket comment the MCP tool just created.
bitbucket_comment() {
  local slug pr id repo
  slug="$(printf '%s' "$payload" | jq -r '.tool_input.repository_name // empty')"
  pr="$(printf '%s' "$payload" | jq -r '.tool_input.pull_request_id // empty | tostring')"
  # The created comment's id, wherever the MCP server put it: a JSON object, or
  # JSON text inside a content block.
  id="$(printf '%s' "$payload" | jq -r '
    [.tool_response | .. | (objects | .id? // empty),
                           (strings | (try fromjson catch null) | objects? | .id? // empty)]
    | map(select(type == "number")) | first // empty')"
  [ -n "$slug" ] && [ -n "$pr" ] && [ -n "$id" ] || return 0

  repo="$(bash "$PRW" list --session "$session" 2>/dev/null \
    | awk -v s="/$slug#$pr" 'index($1, s) && substr($1, length($1) - length(s) + 1) == s { sub(/#.*/, "", $1); print $1; exit }')"
  [ -n "$repo" ] || return 0
  bash "$PRW" ignore-comment "$repo" "$pr" "$id" --session "$session" >/dev/null 2>&1
}

# github_comment — record the GitHub comments a `gh` command just created. The
# URL of each comment is in the output: the text of `gh pr comment`, the
# html_url field of `gh api`. A repo key is github:OWNER/REPO.
github_comment() {
  local cmd out urls url repo pr id
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
  printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])gh[[:space:]]+(pr[[:space:]]+comment|api)([[:space:]]|$)' || return 0
  out="$(printf '%s' "$payload" | jq -r '.tool_response | if type == "string" then . else (.stdout // "") + "\n" + (.content // "" | tostring) end')"
  urls="$(printf '%s\n' "$out" | grep -oE 'https://github\.com/[^/[:space:]"]+/[^/[:space:]"]+/pull/[0-9]+#(issuecomment-|discussion_r)[0-9]+')"
  printf '%s\n' "$urls" | while IFS= read -r url; do
    [ -n "$url" ] || continue
    repo="github:$(printf '%s' "$url" | sed -E 's#https://github\.com/([^/]+/[^/]+)/pull/.*#\1#')"
    pr="$(printf '%s' "$url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"
    id="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
    bash "$PRW" ignore-comment "$repo" "$pr" "$id" --session "$session" >/dev/null 2>&1
  done
}

case "$tool" in
  Bash) github_comment ;;
  *) bitbucket_comment ;;
esac
exit 0
