#!/usr/bin/env bash
# session-start-hook.sh — Claude Code SessionStart hook.
#
# 1. Makes sure the daemon runs (silently starts it when doctor fails).
# 2. A background `bbw wait` does not survive an app restart: when this
#    session still watches a PR, asks the agent to arm the wait again.
#    Changes that happened meanwhile wait in the events file: late, not lost.
# Exit 0 always. BBW_HOOKS=0 disables it.
set -uo pipefail
[ "${BBW_HOOKS:-1}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/find-bbw.sh" 2>/dev/null \
  || . "$HOME/.agents/hooks/bitbucket-pr-watch-find-bbw.sh" 2>/dev/null || exit 0
find_bbw || exit 0

payload="$(cat)"
session="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$session" ] || exit 0

bash "$BBW" doctor --quiet >/dev/null 2>&1 || bash "$BBW" daemon start >/dev/null 2>&1 || true

prs="$(bash "$BBW" list --session "$session" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"
[ -n "$prs" ] || exit 0
msg="bitbucket-pr-watch: this session watches $prs. Start \`bash $BBW wait --session $session\` with run_in_background now; its exit wakes you with the PR change (changes made while you were away are delivered first)."
jq -cn --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
