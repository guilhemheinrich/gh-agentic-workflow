#!/usr/bin/env bash
# Tests for hooks/pilot-reminder.sh. Run inside a container:
#
#   docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine sh -c \
#     'apk add --no-cache bash jq >/dev/null && bash skills/pilot-session/scripts/test-pilot-reminder.sh'
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
hook="$repo/hooks/pilot-reminder.sh"
cli="$repo/skills/session-meta/scripts/session-meta.py"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export AGENT_SESSION_META_DB="$tmp/meta.sqlite"
fail=0
check() { # name, exit code of the assertion
  if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
run() { printf '{"session_id":"%s","hook_event_name":"%s"}' "$1" "${2:-UserPromptSubmit}" | bash "$hook"; }

# 1. missing store: silent, and the hook must not create it
out="$(run pilot-1)"; rc=$?
[[ -z "$out" && $rc == 0 ]]; check "missing store is silent" $?
[[ ! -e "$AGENT_SESSION_META_DB" ]]; check "hook does not create the store" $?

# 2. registered pilot gets the reminder, under the event it was fired for
python3 "$cli" set --harness claude-code pilot-1 role pilot >/dev/null
out="$(run pilot-1)"
[[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" == UserPromptSubmit ]]; check "pilot: UserPromptSubmit event" $?
[[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" == *"PILOT session"* ]]; check "pilot: reminder text injected" $?
out="$(run pilot-1 SessionStart)"
[[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" == SessionStart ]]; check "pilot: SessionStart event" $?

# 3. everyone else is silent
[[ -z "$(run other-2)" ]]; check "unregistered session is silent" $?
python3 "$cli" set --harness claude-code worker-3 role worker >/dev/null
[[ -z "$(run worker-3)" ]]; check "non-pilot role is silent" $?
python3 "$cli" set --harness codex pilot-5 role pilot >/dev/null
[[ -z "$(run pilot-5)" ]]; check "pilot of another harness is silent" $?

# 4. bad input never fails the turn
printf 'not json' | bash "$hook" >/dev/null; check "bad payload exits 0" $?
[[ -z "$(printf 'not json' | bash "$hook")" ]]; check "bad payload is silent" $?
printf 'garbage' > "$tmp/bad.sqlite"
out="$(printf '{"session_id":"pilot-1"}' | AGENT_SESSION_META_DB="$tmp/bad.sqlite" bash "$hook")"; rc=$?
[[ -z "$out" && $rc == 0 ]]; check "corrupt store is silent" $?
out="$(printf '{"session_id":"pilot-1"}' | PILOT_REMINDER_TEMPLATE="$tmp/nope.md" bash "$hook")"; rc=$?
[[ -z "$out" && $rc == 0 ]]; check "missing template is silent" $?
[[ -z "$(printf '{"session_id":"pilot-1"}' | PILOT_REMINDER=0 bash "$hook")" ]]; check "PILOT_REMINDER=0 disables" $?

exit $fail
