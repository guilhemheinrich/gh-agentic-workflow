#!/usr/bin/env bash
# linear-record.sh — append one Linear lifecycle event to a spec's log.
#
# The log is specs/NNN-slug/linear.json, committed, append-only:
#   {"project": "Widget API", "issue": {"id": "TT-412", "url": "…"}, "events": [{"event": "created", "at": "…", "id": "…", "url": "…"}]}
# linear-lifecycle.sh reads it to know which facts are already handled.
# No model, no network.
#
# Usage: linear-record.sh <spec-dir> <event> [id] [url]
#   created     <ID> <URL>   the agent created the issue
#   linked      <ID> <URL>   the agent linked an existing issue
#   in_progress <ID>         the issue moved to In Progress
#   in_review   <ID> <URL>   the issue moved to In Review; URL is the PR
#   project     <NAME>       the Linear project of this spec (top-level "project"; replaces any earlier one)
#   unavailable              no Linear connector in this session. Machine-local: written to
#                            <git-common-dir>/linear-lifecycle/unavailable.json (never to the committed
#                            log); the hook stays silent for this spec until it expires (default 4 h).
#
# Exit 0 and prints `recorded` or `already-recorded`; exit 2 on bad usage.

set -euo pipefail

usage() { echo "usage: linear-record.sh <spec-dir> <event> [id|project-name] [url]" >&2; exit 2; }
(( $# >= 2 && $# <= 4 )) || usage
command -v jq >/dev/null 2>&1 || { echo "linear-record: jq is required" >&2; exit 2; }

dir="$1" event="$2" id="${3:-}" url="${4:-}"
[[ -d "$dir" ]] || { echo "linear-record: no such spec directory: $dir" >&2; exit 2; }

case "$event" in
  created|linked) [[ -n "$id" && -n "$url" ]] || usage ;;
  in_review)      [[ -n "$id" && -n "$url" ]] || usage ;;
  in_progress)    [[ -n "$id" ]] || usage ;;
  project)        [[ -n "$id" && -z "$url" ]] || usage ;;
  unavailable)    [[ -z "$id" ]] || usage ;;
  *) echo "linear-record: unknown event: $event" >&2; exit 2 ;;
esac
if [[ "$event" != project && -n "$id" ]] && ! [[ "$id" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "linear-record: not a Linear identifier: $id" >&2; exit 2
fi

if [[ "$event" == unavailable ]]; then
  spec="$(basename "$(cd "$dir" && pwd)")"
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || { echo "linear-record: not in a git repository" >&2; exit 2; }
  [[ "$common" = /* ]] || common="$(cd "$dir" && cd "$common" && pwd)"
  state="${LINEAR_LIFECYCLE_STATE:-$common/linear-lifecycle}"
  mkdir -p "$state"
  store="$state/unavailable.json"
  curu='{}'
  [[ -s "$store" ]] && jq -e . "$store" >/dev/null 2>&1 && curu="$(cat "$store")"
  printf '%s' "$curu" | jq --arg s "$spec" --argjson now "$(date +%s)" '.[$s] = $now' >"$store.$$" && mv "$store.$$" "$store"
  echo "recorded"; exit 0
fi

log="$dir/linear.json"
cur='{"events":[]}'
if [[ -s "$log" ]]; then
  jq -e . "$log" >/dev/null 2>&1 || { echo "linear-record: $log is not valid JSON" >&2; exit 2; }
  cur="$(cat "$log")"
fi

if [[ "$event" == project ]]; then
  if [[ "$(printf '%s' "$cur" | jq -r '.project // ""')" == "$id" ]]; then echo "already-recorded"; exit 0; fi
  printf '%s' "$cur" | jq --arg p "$id" '.project = $p' >"$log.$$" && mv "$log.$$" "$log"
  echo "recorded"; exit 0
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
