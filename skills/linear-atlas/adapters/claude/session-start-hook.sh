#!/usr/bin/env bash
# session-start-hook.sh — Claude Code SessionStart hook, matcher `startup|resume`.
#
# A background `lw wait` does not survive an app restart. At every start or
# resume of a session this hook:
#   1. ensures the daemon from its heartbeat (`lw daemon alive || lw daemon
#      start`): no network call, and a healthy daemon is never restarted;
#   2. renews the session's subscriptions and answers with additionalContext
#      (`lw session-start`): the session id and the `lw wait` command to start
#      with run_in_background when it watches something, else one line with the
#      session id and the `lw subscribe` command.
# Lines written while the session was away wait in the store: late, not lost.
# Not on `compact`/`clear`: a running wait survives those.
#
# Finds lw from $LW_BIN, else ../../scripts/lw next to this file. Silent, exit 0
# always. LW_HOOKS=0 disables it. Installed by `lw setup --claude`.
set -u
[ "${LW_HOOKS:-1}" = 1 ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
lw="${LW_BIN:-$here/../../scripts/lw}"
[ -f "$lw" ] || exit 0

session="$(python3 -c '
import json, sys
try:
    sid = json.load(sys.stdin).get("session_id")
except Exception:
    sid = None
print(sid if isinstance(sid, str) else "")
' 2>/dev/null)"
[ -n "$session" ] || exit 0

python3 "$lw" daemon alive >/dev/null 2>&1 || python3 "$lw" daemon start >/dev/null 2>&1 || true

answer="$(python3 "$lw" session-start --session "$session" 2>/dev/null)" || exit 0
[ -n "$answer" ] && printf '%s\n' "$answer"
exit 0
