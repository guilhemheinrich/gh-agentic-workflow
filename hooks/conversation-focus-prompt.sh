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
#      sentences, user language) naming the conversation's main subject,
#      once per user message — not again in a continuation forced by
#      another Stop hook, which conversation-focus-stop.sh lets through.
#      The summary also carries links to the external objects the
#      conversation tracks — the Linear project a pilot session steers, the
#      Linear issue a coding session implements, the pull request or the
#      pipeline under way — repeated in every summary so the reader never
#      scrolls back for them.
#
# Both are judged by the agent itself, which already holds the whole
# conversation: no extra model call. The one fact the agent cannot be
# trusted to hold is the link list: left to its memory of its own previous
# replies, it vanishes after a compaction or a distracted turn. So the hook
# reads the transcript, collects the links of past summaries, and injects
# them as data to carry forward. The "after the reply" half
# (conversation-focus-stop.sh) only verifies rule 2's shape.
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
#   CONVERSATION_FOCUS_REFS=0    keep the summary, drop its reference links
#   CONVERSATION_FOCUS_LINKS     max links carried forward (default 6, 0 = off)

set -uo pipefail

[[ "${CONVERSATION_FOCUS:-1}" == "1" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"

# External (http/https) links found in the italic closing summaries of this
# transcript, joined with " · ": the session's very first summary link (in a
# pilot session, its Linear project) always first, then the others by most
# recent appearance, deduped by URL, capped. Local file links are never
# carried. Only assistant lines holding "](" are parsed, so a 15 MB
# transcript costs one grep, not one jq pass per line. The transcript keeps
# the turns compaction removed from the agent's context.
carried_links() {
  local max="${CONVERSATION_FOCUS_LINKS:-6}" transcript
  [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )) || return 0
  transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
  [[ -n "$transcript" && -f "$transcript" ]] || return 0
  grep -F '"type":"assistant"' "$transcript" 2>/dev/null | grep -F '](' \
    | jq -rs --argjson max "$max" '
        def url: sub("^.*\\]\\("; "");
        def dedupe: reduce .[] as $l ([]; if any(.[]; url == ($l | url)) then . else . + [$l] end);
        [ .[]
          | [ .message.content[]? | select(.type == "text") | .text ] | join("\n")
          | [ splits("\n[ \t]*\n") | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] | last // ""
          | select(test("^\\*[^*]") and test("[^*]\\*$"))
          | [ scan("\\[[^\\]\\n]+\\]\\(https?:[^)\\s]+\\)") ]
          | select(length > 0) ]
        | select(length > 0)
        | ([ .[0][0] ] + (reverse | add)) | dedupe | .[:$max] | join(" · ")' 2>/dev/null
}

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
  lines+=("- Closing summary: end the reply with one final paragraph wrapped in single asterisks (*…*), 2-3 sentences in the user's language, stating the conversation's main subject and where it stands — the whole conversation, not only this turn. Nothing after it. Write it once per user message: when a Stop hook makes you continue after it was written (e.g. a session-title update), do not write it again.")
  if [[ "${CONVERSATION_FOCUS_REFS:-1}" == "1" ]]; then
    lines+=("- Summary references: end that italic paragraph, inside the asterisks, with markdown links to the objects this conversation tracks, separated by ' · ' — the Linear project a pilot session steers, the Linear issue the work implements, the pull request opened or reviewed, the pipeline being watched (e.g. '· [Linear: Broker PA](https://linear.app/…) · [ENG-123](https://linear.app/…) · [PR #28](https://github.com/…)'). External URLs only, never local files. Once a reference has appeared in the conversation, repeat it in every later summary while it still applies. Use only URLs seen in this conversation or returned by a tool; never guess one, and omit the links when there are none.")
    links="$(carried_links)"
    if [[ -n "$links" ]]; then
      lines+=("- References already in your previous summaries (read from the transcript, so they survive compaction) — carry each one unless it no longer applies, then add new ones: $links")
    fi
  fi
fi
(( ${#lines[@]} > 1 )) || exit 0

ctx="$(printf '%s\n' "${lines[@]}")"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
