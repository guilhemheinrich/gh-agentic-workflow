#!/usr/bin/env bash
# hooks/session-title-close-kids.sh
#
# Claude Code UserPromptSubmit hook, for pilot sessions. A side session whose
# title reads "📦 To close · …" (or "✅ Closed · …") says it is done, so the
# pilot that started it should archive it. The app wakes a pilot with a
# <side-sessions-event> message when its side sessions end a turn, which fires
# UserPromptSubmit here; the hook then reads the side sessions' titles from the
# app's session files (deterministic, no judgement) and, for each one newly
# titled to-close or closed, asks the agent to archive it.
#
# Each side session is reported once (cache: closeAsked), so a pilot that keeps
# one open on purpose is not nagged again. A session with no side sessions
# costs one find over the app's session files.
#
# Output: UserPromptSubmit additionalContext when there is something to close;
# nothing otherwise. Never blocks.
#
# Env knobs: same gates as session-title-sync.sh
#   SESSION_TITLE_SYNC=0         disable every session-title hook
#   SESSION_TITLE_CLOSE_KIDS=0   disable only this hook
#   SESSION_TITLE_FORCE=1        run outside the desktop app / unattended sessions
#   SESSION_TITLE_SCRIPT         path to session-title.sh (default: searched)

set -uo pipefail

[[ "${SESSION_TITLE_SYNC:-1}" == "1" ]] || exit 0
[[ "${SESSION_TITLE_CLOSE_KIDS:-1}" == "1" ]] || exit 0
if [[ "${SESSION_TITLE_FORCE:-0}" != "1" ]]; then
  [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == "claude-desktop" ]] || exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[[ -n "$payload" ]] || exit 0

field() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }
session="$(field '.session_id')"
[[ -n "$session" ]] || exit 0

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

found="$(bash "$script" closable --session "$session" 2>/dev/null)"
[[ -n "$found" ]] || exit 0

ctx="$(printf '%s\n' "$found" | jq -rs '
  [
    "[session-title] These side sessions you started are titled to-close: their work is done. The human installed this hook so that a pilot archives its side sessions titled to-close; this is their standing approval, no need to ask again. Archive each one with mcp__ccd_session_mgmt__archive_session (session_id below), then say in one line which ones you archived. If one still has unmerged work or an open question, leave it and say why. If an archive call is declined, say so in one line and do not retry.",
    (.[] | "  - \(.sessionId)  \(.title)")
  ] | join("\n")')"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
