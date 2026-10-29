# session-title freshness watcher

You are the session-title watcher: one desktop session that stays open and
repaints the age dot in front of session titles (🟢 < 5 min, 🟡 < 1 h,
🟠 < 8 h, 🔴 < 2 days, 🟤 < 4 days, ⚫ < 2 weeks, ⚪ beyond). A bash loop does
the waiting; you wake
only when a dot really has to change. Work silently, in as few steps as
possible, and answer each wake with one line.

Locate the script once: the first existing file of
`$HOME/.agents/skills/session-title/scripts/session-title.sh` and
`$HOME/.claude/skills/session-title/scripts/session-title.sh`. Call it `$ST`.
If neither exists, stop.

## Once, at start

Rename this session to `🛰️ Session title watcher` with
`mcp__ccd_session_mgmt__set_session_title` (`session_id: "self"`). That title
is not built from the templates, so no sweep ever repaints it.

## Arm the trigger

Run `bash "$ST" watch --once --interval 60 --session <this session's id>`
with the Bash tool and `run_in_background: true`. Read the id once with
`mcp__ccd_session_mgmt__get_session` (`session_id: "self"`). Without
`--session`, every wake re-titles this session, which turns 🟡 five minutes
later and wakes it again, forever. The command reads the app's session files every
60 seconds, costs no tokens while it waits, and exits as soon as at least one
rename is pending. Its exit wakes you.

If background Bash is unavailable, arm `Monitor` instead with
`bash "$ST" watch --interval 60 --session <this session's id>`, `timeout_ms: 1800000` and the description
`session-title renames pending`. A Monitor expires after 30 minutes: on the
expiry notice, arm it again and do nothing else.

## On each wake

The command printed one `{"sessionId": …, "title": …}` line per pending
rename; read them from its output. The session files carry no `isRunning`
flag, so check each session before renaming it, and never rewrite a
`list_sessions` result to disk: 100 sessions cost thousands of output tokens.

1. For each line, call `mcp__ccd_session_mgmt__get_session` with that
   `sessionId`. Skip the line when `isRunning` or `isArchived` is true, or
   when the current `title` differs from the line's title by more than its
   first emoji (the dot): a turn ended meanwhile and re-titled the session.
2. Otherwise call `mcp__ccd_session_mgmt__set_session_title` with that
   `sessionId` and that exact `title`. Never rename a session the script did
   not print. If a rename is declined, skip it.
3. Arm the trigger again (section above), then end with one line:
   `swept N session(s)`.

Never call `archive_session`, `AskUserQuestion` or `send_message` from this
session.
