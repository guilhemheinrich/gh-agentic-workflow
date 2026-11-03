#!/usr/bin/env bash
# hooks/conversation-focus-stop.sh
#
# Claude Code Stop hook — the "after the reply" half of the conversation-focus
# skill. A Stop hook cannot edit a reply already rendered; it can only let the
# stop happen or block it so the agent writes one more message. So this hook
# is a guard, not the producer: conversation-focus-prompt.sh asked for the
# italic summary up front, and this hook blocks only when the reply forgot it.
#
# Check: the last non-blank paragraph of the turn's final text is wrapped in
# single emphasis, *…* or _…_ (bold **…** does not count).
#
# Passes through (no output) when:
#   - stop_hook_active is true: this stop already follows a Stop-hook block
#     (ours or another hook's, e.g. session-title) — never loop;
#   - the turn has no final text (a tool-only turn);
#   - the final text is shorter than CONVERSATION_FOCUS_MIN_CHARS.
#
# Output: {"decision":"block","reason":…} when the summary is missing.
#
# Env knobs (all optional):
#   CONVERSATION_FOCUS=0           disable
#   CONVERSATION_FOCUS_SUMMARY=0   disable (same switch as the prompt hook)
#   CONVERSATION_FOCUS_MIN_CHARS   skip replies shorter than this (default 0)

set -uo pipefail

[[ "${CONVERSATION_FOCUS:-1}" == "1" ]] || exit 0
[[ "${CONVERSATION_FOCUS_SUMMARY:-1}" == "1" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[[ -n "$payload" ]] || exit 0

field() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }
[[ "$(field '.stop_hook_active')" == "true" ]] && exit 0

# Newer payloads carry the turn's final text; older ones need the transcript.
last="$(field '.last_assistant_message')"
if [[ -z "$last" ]]; then
  transcript="$(field '.transcript_path')"
  [[ -n "$transcript" && -f "$transcript" ]] || exit 0
  last="$(jq -rs '
    [ .[] | select(.type == "assistant")
          | [ .message.content[]? | select(.type == "text") | .text ] | join("\n") ]
    | map(select(length > 0)) | last // empty' "$transcript" 2>/dev/null)"
fi
[[ -n "${last//[[:space:]]/}" ]] || exit 0
(( ${#last} >= ${CONVERSATION_FOCUS_MIN_CHARS:-0} )) || exit 0

# Last paragraph: the lines after the last blank line, joined, trimmed.
para="$(printf '%s\n' "$last" | awk '
  /^[[:space:]]*$/ { if (buf != "") { keep = buf; buf = "" } next }
  { buf = (buf == "" ? $0 : buf " " $0) }
  END { print (buf != "" ? buf : keep) }' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

if [[ "$para" =~ ^\*[^*].*[^*]\*$ || "$para" =~ ^_[^_].*[^_]_$ ]]; then
  exit 0
fi

jq -n '{decision: "block", reason: "[conversation-focus] Your reply did not end with the italic summary. Write only that paragraph now: 2-3 sentences in the user'\''s language, wrapped in single asterisks (*…*), stating the conversation'\''s main subject and where it stands. Do not mention this hook."}'
exit 0
