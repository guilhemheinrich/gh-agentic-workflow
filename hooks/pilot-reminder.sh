#!/usr/bin/env bash
# hooks/pilot-reminder.sh
#
# Claude Code hook (UserPromptSubmit and SessionStart) that re-injects a short
# "you are a pilot, be autonomous" reminder, only in sessions registered as a
# pilot. The pilot-session skill's startup registers the session with
#
#   session-meta.py set --harness claude-code <session-id> role pilot
#
# This hook reads that `role` key from the session-meta store. Any other
# session — unregistered, no store, no python3, unreadable store — gets
# nothing: silent, exit 0, never blocks a turn.
#
# Events: UserPromptSubmit fires on the human's messages AND on the app's
# <side-sessions-event> wake-ups (session-title-close-kids.sh relies on that),
# so it covers every turn of a pilot. SessionStart re-injects after a resume or
# a compaction, before any prompt. Stop is not used: a Stop hook can only
# inject by blocking, which would force an extra turn.
#
# Env knobs (all optional):
#   PILOT_REMINDER=0          disable
#   PILOT_REMINDER_TEMPLATE   path to the reminder text (default: the sibling
#                             skills/pilot-session/templates/pilot-reminder.md)
#   SESSION_META_CLI          path to session-meta.py (default: sibling skill)
#   AGENT_SESSION_META_DB     store location, as for session-meta.py

set -uo pipefail

[[ "${PILOT_REMINDER:-1}" == "1" ]] || exit 0

# Cheapest checks first: no store file means no pilot was ever registered.
db="${AGENT_SESSION_META_DB:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-session/meta.sqlite}"
[[ -f "$db" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -n "$session_id" ]] || exit 0

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
meta_cli="${SESSION_META_CLI:-$hook_dir/../skills/session-meta/scripts/session-meta.py}"
template="${PILOT_REMINDER_TEMPLATE:-$hook_dir/../skills/pilot-session/templates/pilot-reminder.md}"
[[ -f "$meta_cli" && -f "$template" ]] || exit 0

role="$(AGENT_SESSION_META_DB="$db" python3 "$meta_cli" get --harness claude-code "$session_id" --key role 2>/dev/null \
  | jq -r 'strings' 2>/dev/null)"
[[ "$role" == "pilot" ]] || exit 0

event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
case "$event" in
  SessionStart|UserPromptSubmit) ;;
  *) event="UserPromptSubmit" ;;
esac

jq -n --arg e "$event" --rawfile c "$template" \
  '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}' 2>/dev/null
exit 0
