#!/usr/bin/env bash
# hooks/session-title-sync.sh
#
# Claude Code Stop hook. At the end of a turn, gathers the session's facts
# through the session-title skill (spec or free mode, spec-kit stage, git,
# PR, whether the turn ended on a question) and, when they changed since the
# last ask, blocks the stop once with a reason that asks the agent to judge
# the human's next action and rename the session from the fixed templates.
#
# A hook cannot rename a session: the rename is the desktop app's
# set_session_title tool, which only the agent can call. So this hook only
# runs where that tool exists (CLAUDE_CODE_ENTRYPOINT=claude-desktop) and only
# when a human attends the session (unattended sessions decline renames).
#
# Output: {"decision":"block","reason":…} at most once per new fingerprint;
# nothing otherwise. Never loops: a stop already continued by a Stop hook
# (stop_hook_active=true) passes through.
#
# Env knobs (all optional):
#   SESSION_TITLE_SYNC=0     disable unconditionally
#   SESSION_TITLE_FORCE=1    run outside the desktop app / unattended sessions
#   SESSION_TITLE_SCRIPT     path to session-title.sh (default: searched)
#   + every SESSION_TITLE_* knob of session-title.sh

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
[[ "$(field '.stop_hook_active')" == "true" ]] && exit 0
session="$(field '.session_id')"
[[ -n "$session" ]] || exit 0
cwd="$(field '.cwd')"; [[ -n "$cwd" && -d "$cwd" ]] || cwd="$(pwd)"
transcript="$(field '.transcript_path')"

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

# Newer payloads carry the turn's final text; older ones need the transcript.
lastfile=""
last="$(field '.last_assistant_message')"
if [[ -n "$last" ]]; then
  lastfile="$(mktemp)" && printf '%s' "$last" >"$lastfile"
fi

state="$(bash "$script" check --repo "$cwd" --session "$session" \
  ${transcript:+--transcript "$transcript"} ${lastfile:+--last-message-file "$lastfile"} 2>/dev/null)"
[[ -n "$lastfile" ]] && rm -f "$lastfile"
[[ -n "$state" ]] || exit 0
[[ "$(printf '%s' "$state" | jq -r '.changed' 2>/dev/null)" == "true" ]] || exit 0

templates="$(cd "$(dirname "$script")/.." && pwd)/templates/titles.json"

reason="$(printf '%s' "$state" | jq -r --arg script "$script" --arg session "$session" \
  --slurpfile tpl "$templates" '
  . as $f
  | ($tpl[0].statuses) as $st
  | [
      "[session-title] Update this session title to the HUMAN next action. Do not mention this to the user.",
      "",
      "Facts:",
      "- mode: \(.mode) (\(.modeReason))",
      (if .spec then "- spec: \(.spec.slug), stage \(.spec.stage), tasks \(.spec.done)/\(.spec.total)" else empty end),
      "- git: branch \(.git.branch // "?"), \(.git.dirty) uncommitted file(s), \(.git.ahead) unpushed commit(s)\(if .git.mergedByAncestry then ", already in origin/\(.git.base)" else "" end)",
      "- pr: \(if .pr then "#\(.pr.number) \(.pr.state)" else "none found" end)",
      "- turn ended on a question: \(.endsWithQuestion)",
      "- current title: \(.currentTitle | if . == "" then "(unknown)" else . end)",
      "",
      "Suggested: \(.suggested | join(" or ")). Choose from the allowed statuses of \(.mode) mode, by what the human must do next:",
      (.allowed[] | "- \(.) — \($st[.].next)"),
      "",
      "Then run:",
      "  bash \"\($script)\" set <status> --session \"\($session)\" --repo \"\(.root)\"\(if .mode == "free" then " --subject \"<topic in 2-5 words, user language>\"" else "" end)",
      "It prints the title, or UNCHANGED. If it prints a title, call mcp__ccd_session_mgmt__set_session_title with session_id \"self\" and that exact title. Then stop."
    ] | join("\n")')"

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
