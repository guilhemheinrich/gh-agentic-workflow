#!/usr/bin/env bash
# hooks/session-title-watcher-check.sh
#
# Claude Code SessionStart hook. Age dots ("🟡 🔀 To merge #12 · x") only move
# while one freshness watcher session runs on this machine. Nothing restarts it
# when the app quits or the watcher is archived, and a fresh device has none,
# so every dot freezes silently. This hook reads the watcher heartbeat
# (`session-title.sh watcher-status`) and, when no watcher is alive, asks the
# agent to propose one: a "New task" card the human starts with one click.
#
# The watcher must run in its own worktree: a side session that shares its
# parent's checkout cannot be detached, and an attached watcher reports every
# wake back to the session that started it. The watcher detaches itself at
# start (templates/freshness-watch.md).
#
# Output: SessionStart additionalContext; nothing when a watcher is alive,
# freshness is off, the gates fail, or another session nagged less than
# SESSION_TITLE_NAG_TTL seconds ago (default 1800), so opening five sessions
# shows one card, not five.
#
# Env knobs: same gates as session-title-sync.sh
#   SESSION_TITLE_SYNC=0      disable unconditionally
#   SESSION_TITLE_FORCE=1     run outside the desktop app / unattended sessions
#   SESSION_TITLE_SCRIPT      path to session-title.sh (default: searched)
#   SESSION_TITLE_NAG_TTL     seconds between two proposals on this machine

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
# A compaction or a /clear is not a new session: the human already saw the card.
case "$(field '.source')" in compact|clear) exit 0 ;; esac

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

status="$(bash "$script" watcher-status 2>/dev/null)"
state="$(printf '%s' "$status" | jq -r '.state // empty' 2>/dev/null)"
[[ "$state" == "never" || "$state" == "down" ]] || exit 0

cache="${SESSION_TITLE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/session-title}"
nag="$cache/watch-nag"
now="$(date +%s)"
last="$(cat "$nag" 2>/dev/null || echo 0)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
(( now - last >= ${SESSION_TITLE_NAG_TTL:-1800} )) || exit 0
mkdir -p "$cache" 2>/dev/null && printf '%s\n' "$now" >"$nag"

template="$(cd "$(dirname "$script")/.." && pwd)/templates/freshness-watch.md"
template="${template/#$HOME/~}"
if [[ "$state" == "never" ]]; then
  why="no freshness watcher has ever run on this machine"
else
  why="the freshness watcher stopped $(( $(printf '%s' "$status" | jq -r '.ageSeconds // 0') / 60 )) minutes ago (app restarted, or watcher session archived)"
fi

ctx="$(jq -rn --arg why "$why" --arg t "$template" '[
  "[session-title] \($why), so the age dots in front of session titles do not move.",
  "Unless your own task in this session is to follow \($t) (then ignore this note), propose a watcher once, alongside your answer to the first message, never instead of it:",
  "- Call mcp__ccd_session__start_session (load it with ToolSearch \"select:mcp__ccd_session__start_session\" if it is deferred) with initiation \"own_initiative\", context \"fresh\", use_worktree true, name \"pastilles-watch\", a title naming the freshness-dot watcher in the user language, prompt \"Read and follow \($t)\", and a background saying that this session repaints idle session age dots, must stay open, and detaches itself at start.",
  "- use_worktree must be true: a side session sharing this checkout cannot be detached, and an attached watcher would report every wake back here.",
  "- Tell the user in one sentence that the dots are frozen and that the card starts the watcher."
] | join("\n")')"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0
