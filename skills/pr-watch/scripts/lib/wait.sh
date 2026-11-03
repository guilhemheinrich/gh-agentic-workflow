#!/usr/bin/env bash
# wait.sh — `prw wait`, the session's doorbell, and `prw status`.

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
      *) echo "prw wait: unknown option $1" >&2; return 64 ;;
    esac
    shift
  done
  [ -n "$session" ] || { echo "prw wait: --session is required" >&2; return 64; }

  # One doorbell per session: two waits would both deliver the same line and
  # both advance the cursor, losing the next one. A second wait exits at once.
  local lock pid
  lock="$(prw_state_dir)/waits/$(safe_name "$session").lock"
  mkdir -p "$(dirname "$lock")"
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "already waiting (pid $pid)"
      return 4
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "already waiting"; return 4; }
  fi
  printf '%s\n' "$$" >"$lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" EXIT
  trap 'exit 143' INT TERM

  start="$(date +%s)"
  while :; do
    lines="$(events_unread "$session")"
    # The daemon appends the released lines before it drops the queue, and
    # closes the subscription before it releases: once the session has no
    # work left, a second read sees anything released in between.
    if [ -z "$lines" ] && ! session_has_work "$session"; then
      lines="$(events_unread "$session")"
      if [ -z "$lines" ]; then
        echo "no open subscription"
        return 3
      fi
    fi
    if [ -n "$lines" ]; then
      n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
      printf '%s\n' "$lines" | jq -r '.text'
      events_ack "$session" "$n"
      # A wake line does not end the watch: after `merged` the daemon still
      # follows the destination pipeline. Say so, or the session forgets to
      # arm the next wait and never hears the verdict.
      if session_has_work "$session"; then
        echo "prw: still watching (post-merge pipeline or open PR) — run \`prw wait --session $session\` again with run_in_background."
      fi
      return 0
    fi
    if [ -n "$timeout" ] && [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      return 2
    fi
    sleep "${PRW_WAIT_POLL:-2}"
  done
}

# status_line SNAPSHOT_FILE — one human line from the last snapshot.
status_line() {
  jq -r '
    if .phase == "build" then
      ((.repo | split("/") | last) + "@" + .commit[0:7]) as $id
      | ([.statuses[] | "\(.name) \(.state)"] | join(", ")) as $st
      | [$id + " build", (if $st != "" then $st else "no pipeline yet" end), "as of \(.fetched_at)"] | join(" · ")
    else
    ((.repo | split("/") | last) + "#" + (.pr | tostring)) as $id
    | ([.statuses[] | "\(.name) \(.state)"] | join(", ")) as $st
    | ([.participants[] | if .state == "approved" then "approved by \(.name)" else "changes requested by \(.name)" end] | join(", ")) as $rv
    | ([.comments[] | select(.deleted | not)] | length) as $nc
    | [$id + " " + .state]
      + (if $st != "" then [$st] else [] end)
      + (if $rv != "" then [$rv] else [] end)
      + ["\($nc) comment\(if $nc == 1 then "" else "s" end)",
         "conflict \(if .conflict then "YES" else "no" end)",
         "as of \(.fetched_at)"]
    | join(" · ")
    end' "$1"
}

cmd_status() {
  local filter repo pr snap targets
  # A PR line, plus a build line while a commit is followed.
  targets='(select(.pr != null) | "\(.repo) \(.pr)"), (select(.status == "build" and .commit != null) | "\(.repo) commit-\(.commit)")'
  case "${1:-}" in
    --session) filter=".[] | select(.session == \$s) | $targets" ;;
    "") repo="$(repo_from_remote)"; filter=".[] | select(.repo == \$r) | $targets" ;;
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
