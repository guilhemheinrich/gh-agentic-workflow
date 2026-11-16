#!/usr/bin/env bash
# A pilot's side session titled "📦 To close" (any age dot) or "✅ Closed" is reported once
# by `closable` and by the close-kids hook; other titles, archived, detached and foreign
# sessions are not.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ST="$here/../scripts/session-title.sh"; HOOK="$here/../../../hooks/session-title-close-kids.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SESSION_TITLE_APP_DIR="$T/app" SESSION_TITLE_CACHE="$T/cache" HOME="$T/home"; mkdir -p "$T/app" "$T/home"
mk() { # id title [extra json]
  jq -nc --arg id "$1" --arg t "$2" --argjson x "${3:-{\}}" \
    '{sessionId:$id,title:$t,isArchived:false,spawnedFrom:{sessionId:"local_pilot"}} * $x' >"$T/app/$1.json"; }
jq -nc '{sessionId:"local_pilot",cliSessionId:"cli-pilot",title:"🟡 🧭 Piloting · p"}' >"$T/app/local_pilot.json"
mk local_a "🟢 📦 To close · a"
mk local_b "✅ Closed · b"
mk local_c "🟠 💬 To read · c"
mk local_d "🟢 📦 To close · d" '{"isArchived":true}'
mk local_e "🟢 📦 To close · e" '{"lineageDetached":true}'
mk local_f "🟢 📦 To close · f" '{"spawnedFrom":{"sessionId":"local_other"}}'
got="$(bash "$ST" closable --session cli-pilot | jq -sc 'map(.sessionId) | sort')"
[[ "$got" == '["local_a","local_b"]' ]] || { echo "FAIL closable: $got"; exit 1; }
[[ -z "$(bash "$ST" closable --session cli-pilot)" ]] || { echo "FAIL: reported twice"; exit 1; }
[[ "$(bash "$ST" closable --session cli-pilot --all | wc -l | tr -d ' ')" == 2 ]] || { echo "FAIL --all"; exit 1; }
mk local_g "🟡 📦 À clôturer · g"
out="$(printf '{"session_id":"cli-pilot"}' | SESSION_TITLE_FORCE=1 SESSION_TITLE_SCRIPT="$ST" bash "$HOOK")"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("local_g") and (test("local_a") | not)' >/dev/null \
  || { echo "FAIL hook: $out"; exit 1; }
[[ -z "$(printf '{"session_id":"cli-pilot"}' | SESSION_TITLE_FORCE=1 SESSION_TITLE_SCRIPT="$ST" bash "$HOOK")" ]] \
  || { echo "FAIL hook: reported twice"; exit 1; }
echo PASS
