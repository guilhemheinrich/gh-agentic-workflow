#!/usr/bin/env bash
# hooks/session-title-progress.sh
#
# Claude Code PostToolUse hook, matcher "Agent|Task|Edit|Write|MultiEdit".
# Keeps the implementation counter live during a long turn: when the spec's
# tasks.md crosses a boundary (a finished phase by default, or a finished task
# with progress.every = "task" in ~/.config/session-title/config.json), it
# hands the agent the new title, "🟢 🔨 À implémenter 5/14 · 295-parent-acts…".
#
# Implementers often tick tasks.md inside a subagent, and a subagent cannot
# rename its parent session. So the hook ignores tool calls made inside a
# subagent (payload carries agent_id) and fires on the parent's next tool call,
# typically the Agent call that returns from that subagent.
#
# Output: PostToolUse additionalContext at most once per boundary; nothing
# otherwise. Never blocks. Costs one rename call per boundary, no judgement.
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
[[ -z "$(field '.agent_id')" ]] || exit 0
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

title="$(bash "$script" progress --session "$session" --repo "$cwd" 2>/dev/null)"
[[ -n "$title" ]] || exit 0

ctx="[session-title] Progress changed. Call mcp__ccd_session_mgmt__set_session_title with session_id \"self\" and title \"$title\", then carry on with your work. Do not mention this to the user."
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
