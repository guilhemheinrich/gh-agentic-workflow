#!/usr/bin/env bash
# Regression: the freshness watcher keeps spawnedFrom = its pilot, and each wake bumps its
# lastActivityAt. It must not count as news for the pilot (sweep) nor as a child (children).
# Fake APP_DIR: pilot (idle 30 min), normal child (idle 2 h), watcher (title 🛰️, active now),
# detached child (lineageDetached, active now). Expect the pilot to stay 🟡 and Piloting x/1.
set -euo pipefail
ST="$(cd "$(dirname "$0")/../scripts" && pwd)/session-title.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SESSION_TITLE_APP_DIR="$T/app" SESSION_TITLE_CACHE_DIR="$T/cache" HOME="$T/home"; mkdir -p "$T/app" "$T/home"
now=$(date +%s); iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
mk() { # id title ageSeconds [extra json]
  jq -nc --arg id "$1" --arg t "$2" --argjson at "$(( (now-$3)*1000 ))" --argjson x "${4:-{\}}" \
    '{sessionId:$id,title:$t,isArchived:false,lastActivityAt:$at,spawnedFrom:{sessionId:"local_pilot"}} * $x' >"$T/app/$1.json"; }
mk local_kid "🟠 💬 To read · kid" 7200
mk local_watch "🛰️ Session title watcher" 5 '{"lineageDetached":true}'
mk local_det "🟢 💬 To read · detached" 5 '{"lineageDetached":true}'
jq -n --argjson at "$(( (now-1800)*1000 ))" '{sessionId:"local_pilot",title:"🟡 🧭 Piloting · p",isArchived:false,lastActivityAt:$at}' >"$T/app/local_pilot.json"
jq -n --arg a "$(iso $((now-1800)))" '[{sessionId:"local_pilot",title:"🟢 🧭 Piloting · p",isArchived:false,isRunning:false,lastActivityAt:$a}]' >"$T/list.json"
out="$(bash "$ST" sweep --sessions "$T/list.json")"
# pilot idle 30 min, no live child: 🟡 expected, so the 🟢 title is repainted to 🟡 without news
echo "$out" | jq -e 'select(.title|startswith("🟡 ")) | (.news // false) == false' >/dev/null || { echo "FAIL sweep: $out"; exit 1; }
# same with the watcher marked by title only (no lineageDetached)
jq 'del(.lineageDetached)' "$T/app/local_watch.json" >"$T/w" && mv "$T/w" "$T/app/local_watch.json"
bash "$ST" sweep --sessions "$T/list.json" | jq -e '.news // false | not' >/dev/null || { echo "FAIL title marker"; exit 1; }
echo PASS
