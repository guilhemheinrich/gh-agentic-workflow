#!/usr/bin/env bash
# push-hook.sh — Claude Code PostToolUse hook (matcher: Bash).
#
# After a successful `git push`, subscribes this session to the open PR of the
# pushed branch (or a pending subscription if the PR does not exist yet),
# records the pushed head as the session's own, and tells the agent to arm
# `bbw wait` in the background. That background command is the doorbell:
# Claude re-invokes the session when it exits.
#
# Never blocks, never fails the turn: any problem means no output, exit 0.
# BBW_HOOKS=0 disables it.
set -uo pipefail
[ "${BBW_HOOKS:-1}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/find-bbw.sh" 2>/dev/null \
  || . "$HOME/.agents/hooks/bitbucket-pr-watch-find-bbw.sh" 2>/dev/null || exit 0
find_bbw || exit 0

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)' || exit 0
session="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$session" ] && [ -n "$cwd" ] || exit 0

branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
[ -n "$branch" ] || exit 0
res="$(cd "$cwd" && bash "$BBW" subscribe --branch "$branch" --session "$session" --harness claude --head "$head" 2>/dev/null)" || exit 0

case "$res" in
  subscribed*) msg="bitbucket-pr-watch: $res for this session." ;;
  pending*) msg="bitbucket-pr-watch: $res (no open PR yet; the daemon resolves it once the PR exists)." ;;
  *) exit 0 ;;
esac
msg="$msg If no \`bbw wait --session $session\` is already running, start \`bash $BBW wait --session $session\` now with run_in_background; its exit wakes you with the PR change."
jq -cn --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
