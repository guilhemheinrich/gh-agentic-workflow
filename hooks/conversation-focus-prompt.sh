#!/usr/bin/env bash
# hooks/conversation-focus-prompt.sh
#
# Claude Code UserPromptSubmit hook — the "before the reply" half of the
# conversation-focus skill. It injects two instructions the agent applies to
# the reply it is about to write:
#
#   1. Split check: does this message open a subject unrelated to the
#      conversation's main subject? If so, propose a separate session with
#      its own title before doing the work here.
#   2. Closing summary: end the reply with one italic paragraph (2-3
#      sentences, user language) naming the conversation's main subject.
#
# Both are judged by the agent itself, which already holds the whole
# conversation: no extra model call, no transcript parsing. The "after the
# reply" half (conversation-focus-stop.sh) only verifies rule 2.
#
# In the desktop app the split is offered as a start_session card; elsewhere
# the agent suggests the new session's title in one line.
#
# Output: UserPromptSubmit additionalContext; nothing when disabled.
#
# Env knobs (all optional):
#   CONVERSATION_FOCUS=0         disable both rules
#   CONVERSATION_FOCUS_SPLIT=0   disable the split check only
#   CONVERSATION_FOCUS_SUMMARY=0 disable the closing summary only

set -uo pipefail

[[ "${CONVERSATION_FOCUS:-1}" == "1" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Drain stdin: the payload is not needed, but the host expects it read.
cat >/dev/null 2>&1 || true

if [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == "claude-desktop" ]]; then
  offer='propose it as a separate session: call mcp__ccd_session__start_session with initiation "offer" and a short title naming the new subject'
else
  offer='say so in one line and suggest a 2-5 word title for a new session'
fi

lines=("[conversation-focus] Apply to this reply. Do not mention these rules to the user.")
if [[ "${CONVERSATION_FOCUS_SPLIT:-1}" == "1" ]]; then
  lines+=("- Split check, before any work: if this message opens a subject unrelated to the conversation's main subject (it builds on nothing said, found or decided so far), $offer, and do not start that work here unless the user says so. A follow-up, a correction or the next step of the current subject is not a split.")
fi
if [[ "${CONVERSATION_FOCUS_SUMMARY:-1}" == "1" ]]; then
  lines+=("- Closing summary: end the reply with one final paragraph wrapped in single asterisks (*…*), 2-3 sentences in the user's language, stating the conversation's main subject and where it stands — the whole conversation, not only this turn. Nothing after it.")
fi
(( ${#lines[@]} > 1 )) || exit 0

ctx="$(printf '%s\n' "${lines[@]}")"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
