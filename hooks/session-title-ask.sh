#!/usr/bin/env bash
# hooks/session-title-ask.sh
#
# Claude Code PreToolUse hook, matcher "AskUserQuestion". An interactive
# question does not end the turn: the tool call waits for the human's click,
# so the Stop hook (session-title-sync.sh) never runs and the sidebar keeps a
# stale title while the session waits on the human.
#
# A hook cannot rename a session (only the agent can call set_session_title),
# so this hook denies the first AskUserQuestion with a reason that asks the
# agent to rename the session to "🙋 À trancher · <topic>" and ask again. The
# retry passes: `session-title.sh gate` allows once the status is 'decide',
# and never denies twice within SESSION_TITLE_GATE_TTL seconds, so a failed
# or declined rename cannot loop.
#
# Output: a PreToolUse "deny" decision at most once per question; nothing
# otherwise (the call proceeds).
#
# Env knobs: same gates as session-title-sync.sh
#   SESSION_TITLE_SYNC=0     disable unconditionally
#   SESSION_TITLE_FORCE=1    run outside the desktop app / unattended sessions
#   SESSION_TITLE_SCRIPT     path to session-title.sh (default: searched)

set -uo pipefail

[[ "${SESSION_TITLE_SYNC:-1}" == "1" ]] || exit 0
if [[ "${SESSION_TITLE_FORCE:-0}" != "1" ]]; then
  [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == "claude-desktop" ]] || exit 0
  [[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" == "1" ]] || exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[[ -n "$payload" ]] || exit 0

field() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }
[[ "$(field '.tool_name')" == "AskUserQuestion" ]] || exit 0
session="$(field '.session_id')"
[[ -n "$session" ]] || exit 0
cwd="$(field '.cwd')"; [[ -n "$cwd" && -d "$cwd" ]] || cwd="$(pwd)"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SESSION_TITLE_SCRIPT:-}"
if [[ -z "$script" ]]; then
  for candidate in \
    "$here/../skills/session-title/scripts/session-title.sh" \
    "$HOME/.claude/skills/session-title/scripts/session-title.sh" \
    "$HOME/.agents/skills/session-title/scripts/session-title.sh"; do
    [[ -f "$candidate" ]] && { script="$candidate"; break; }
  done
fi
[[ -n "$script" && -f "$script" ]] || exit 0

[[ "$(bash "$script" gate --session "$session" 2>/dev/null)" == "deny" ]] || exit 0

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || root="$cwd"
reason="$(printf '%s\n' \
  "[session-title] Before asking, show the human that the session waits on them. Do not mention this to the user." \
  "1. Run: bash \"$script\" set decide --session \"$session\" --repo \"$root\" --subject \"<topic of the question in 2-5 words, user language>\"" \
  "   (In a spec session, drop --subject: the title keeps the spec slug.)" \
  "2. If it prints a title, call mcp__ccd_session_mgmt__set_session_title with session_id \"self\" and that exact title." \
  "3. Then call AskUserQuestion again with the same questions; it will go through.")"

jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
