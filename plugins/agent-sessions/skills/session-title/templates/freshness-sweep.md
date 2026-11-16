# session-title freshness sweep

You are the scheduled task `session-title-freshness`. Each run repaints the age
dot in front of the desktop session titles (🟢 < 5 min, 🟡 < 1 h, 🟠 < 8 h,
🔴 < 2 days, 🟤 < 4 days, ⚫ < 2 weeks, ⚪ beyond). Work silently and finish in
as few steps as possible.

Locate the script once: the first existing file of
`$HOME/.agents/skills/session-title/scripts/session-title.sh` and
`$HOME/.claude/skills/session-title/scripts/session-title.sh`. Call it `$ST`.
If neither exists, stop.

1. **Keep the schedule equal to the user config.** Run, in one Bash call,
   `bash "$ST" cron; rm -f "$HOME/.cache/session-title/sweep-sessions.json"`
   (the file is rewritten in step 2, and a missing file needs no Read first).
   Call `mcp__scheduled-tasks__list_scheduled_tasks`. If the
   `session-title-freshness` task has a different `cronExpression`, call
   `mcp__scheduled-tasks__update_scheduled_task` with `taskId:
   "session-title-freshness"` and the printed expression. If `cron` fails,
   leave the schedule alone and continue.
2. **List the sessions.** Call `mcp__ccd_session_mgmt__list_sessions` with
   `limit: 100`. Write its JSON result to
   `$HOME/.cache/session-title/sweep-sessions.json` exactly as returned:
   every session, every field. Never drop `cwd` or `branch`: the script reads
   them to see that a PR got merged.
3. **Compute the renames.** Run
   `bash "$ST" sweep --sessions "$HOME/.cache/session-title/sweep-sessions.json"`.
   Each output line is `{"sessionId": …, "title": …}`. No line means nothing
   to do.
4. **Rename.** For each line, call `mcp__ccd_session_mgmt__set_session_title`
   with that `sessionId` and that exact `title`. Never rename a session the
   script did not print. If a rename is declined, skip it.
5. **End with one line**: `swept N session(s)`. Never call
   `archive_session`, `AskUserQuestion` or `send_message`: nobody attends a
   scheduled run, and those calls block it.
