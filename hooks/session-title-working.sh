#!/usr/bin/env bash
# hooks/session-title-working.sh
#
# Claude Code UserPromptSubmit hook. The moment the human sends a message, the
# old title ("🟠 🧪 À tester · …") is wrong: the human now waits on the agent.
# This hook asks the agent to make its FIRST tool call a rename to the working
# title naming what IT does, "🔵 🛠️ Coding · <topic>" (fixed activity catalogue), as soon as it has read the message and
# before any other work.
#
# A spec session gets the exact title (its subject is the spec slug). A free
# session gets the template, and the agent writes a topic that fits the new
# message. At Stop, session-title-sync.sh replaces the working title: through
# the usual judgement when the facts changed, or by restoring the previous
# title in one call when they did not.
#
# Output: UserPromptSubmit additionalContext; nothing when the gates fail.
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

bash "$script" scheduled --transcript "$(field '.transcript_path')" 2>/dev/null && exit 0

menu="$(bash "$script" working --session "$session" --repo "$cwd" 2>/dev/null)"
[[ -n "$menu" ]] || exit 0

ctx="$(printf '%s' "$menu" | jq -r '
  (if .dot == "" then "" else "\(.dot) " end) as $d
  | [
      "[session-title] As soon as you have read this message, and before any other work, make your FIRST tool call mcp__ccd_session_mgmt__set_session_title with session_id \"self\" and a title saying what YOU are about to do:",
      (if .subject then "  \"\($d)<icon> <Activity> · \(.subject)\"  (keep the subject exactly: it is the spec folder)"
       else "  \"\($d)<icon> <Activity> · <topic>\"  (<topic>: 2-5 words in the user language naming what this message asks)" end),
      "Pick the one activity that matches, and copy what comes before the dash exactly (icon, label, counter if any):",
      (.activities[] | "  - \(.)"),
      "Do not mention this to the user."
    ] | join("\n")')"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
