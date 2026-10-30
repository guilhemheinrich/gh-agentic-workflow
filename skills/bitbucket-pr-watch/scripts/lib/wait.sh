#!/usr/bin/env bash
# wait.sh — `bbw wait`, the session's doorbell, and `bbw status`.

# session_has_work SESSION — an open or pending subscription, or a queued line
# the daemon has not released yet.
session_has_work() {
  local n
  n="$(store_subscriptions_jq '[.[] | select(.session == $s and .status != "closed")] | length' --arg s "$1")"
  [ "$n" -gt 0 ] && return 0
  [ -s "$(pending_path "$1").jsonl" ]
}

cmd_wait() {
  local session="" timeout="" start lines n
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session="$2"; shift ;;
      --timeout) timeout="$2"; shift ;;
      *) echo "bbw wait: unknown option $1" >&2; return 64 ;;
    esac
    shift
  done
  [ -n "$session" ] || { echo "bbw wait: --session is required" >&2; return 64; }
  start="$(date +%s)"
  while :; do
    lines="$(events_unread "$session")"
    if [ -n "$lines" ]; then
      n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
      printf '%s\n' "$lines" | jq -r '.text'
      events_ack "$session" "$n"
      return 0
    fi
    if ! session_has_work "$session"; then
      echo "no open subscription"
      return 3
    fi
    if [ -n "$timeout" ] && [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      return 2
    fi
    sleep "${BBW_WAIT_POLL:-2}"
  done
}

# status_line SNAPSHOT_FILE — one human line from the last snapshot.
status_line() {
  jq -r '
    (.repo | split("/") | last) + "#" + (.pr | tostring) as $id
    | ([.statuses[] | "\(.name) \(.state)"] | join(", ")) as $st
    | ([.participants[] | if .state == "approved" then "approved by \(.name)" else "changes requested by \(.name)" end] | join(", ")) as $rv
    | ([.comments[] | select(.deleted | not)] | length) as $nc
    | [$id + " " + .state]
      + (if $st != "" then [$st] else [] end)
      + (if $rv != "" then [$rv] else [] end)
      + ["\($nc) comment\(if $nc == 1 then "" else "s" end)",
         "conflict \(if .conflict then "YES" else "no" end)",
         "as of \(.fetched_at)"]
    | join(" · ")' "$1"
}

cmd_status() {
  local filter repo pr snap
  case "${1:-}" in
    --session) filter='.[] | select(.session == $s and .pr != null) | "\(.repo) \(.pr)"' ;;
    "") repo="$(repo_from_remote)"; filter='.[] | select(.repo == $r and .pr != null) | "\(.repo) \(.pr)"' ;;
    *) repo="$1"; pr="${2:-}" ;;
  esac
  if [ -n "${pr:-}" ]; then
    snap="$(snapshot_path "$repo" "$pr")"
    if [ -f "$snap" ]; then status_line "$snap"; else echo "$repo#$pr: no snapshot yet (is the daemon running?)"; fi
    return 0
  fi
  store_subscriptions_jq -r "[$filter] | unique[]" --arg s "${2:-}" --arg r "${repo:-}" \
  | while read -r repo pr; do
      snap="$(snapshot_path "$repo" "$pr")"
      if [ -f "$snap" ]; then status_line "$snap"; else echo "$repo#$pr: no snapshot yet"; fi
    done
}
