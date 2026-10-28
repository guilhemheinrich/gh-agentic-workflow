#!/usr/bin/env bash
# linear-record.sh — append one Linear lifecycle event to a spec's log.
#
# The log is specs/NNN-slug/linear.json, committed, append-only:
#   {"issue": {"id": "TT-412", "url": "…"}, "events": [{"event": "created", "at": "…", "id": "…", "url": "…"}]}
# linear-lifecycle.sh reads it to know which facts are already handled.
# No model, no network.
#
# Usage: linear-record.sh <spec-dir> <event> [id] [url]
#   created     <ID> <URL>   the agent created the issue
#   linked      <ID> <URL>   the agent linked an existing issue
#   in_progress <ID>         the issue moved to In Progress
#   in_review   <ID> <URL>   the issue moved to In Review; URL is the PR
#   unavailable              no Linear connector: the lifecycle hook goes silent for this spec
#
# Exit 0 and prints `recorded` or `already-recorded`; exit 2 on bad usage.

set -euo pipefail

usage() { echo "usage: linear-record.sh <spec-dir> <event> [id] [url]" >&2; exit 2; }
(( $# >= 2 && $# <= 4 )) || usage
command -v jq >/dev/null 2>&1 || { echo "linear-record: jq is required" >&2; exit 2; }

dir="$1" event="$2" id="${3:-}" url="${4:-}"
[[ -d "$dir" ]] || { echo "linear-record: no such spec directory: $dir" >&2; exit 2; }

case "$event" in
  created|linked) [[ -n "$id" && -n "$url" ]] || usage ;;
  in_review)      [[ -n "$id" && -n "$url" ]] || usage ;;
  in_progress)    [[ -n "$id" ]] || usage ;;
  unavailable)    [[ -z "$id" ]] || usage ;;
  *) echo "linear-record: unknown event: $event" >&2; exit 2 ;;
esac
if [[ -n "$id" ]] && ! [[ "$id" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "linear-record: not a Linear identifier: $id" >&2; exit 2
fi

log="$dir/linear.json"
cur='{"events":[]}'
if [[ -s "$log" ]]; then
  jq -e . "$log" >/dev/null 2>&1 || { echo "linear-record: $log is not valid JSON" >&2; exit 2; }
  cur="$(cat "$log")"
fi

if printf '%s' "$cur" | jq -e --arg e "$event" --arg id "$id" --arg url "$url" \
  'any(.events[]?; .event == $e and (.id // "") == $id and (.url // "") == $url)' >/dev/null; then
  echo "already-recorded"; exit 0
fi

tmp="$log.$$"
printf '%s' "$cur" | jq --arg e "$event" --arg id "$id" --arg url "$url" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .events = ((.events // []) + [{event: $e, at: $at}
    + (if $id != "" then {id: $id} else {} end)
    + (if $url != "" then {url: $url} else {} end)])
  | if ($e == "created" or $e == "linked") then .issue = {id: $id, url: $url} else . end' >"$tmp"
mv "$tmp" "$log"
echo "recorded"
