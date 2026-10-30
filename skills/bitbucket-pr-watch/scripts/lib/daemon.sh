#!/usr/bin/env bash
# daemon.sh — the poll loop. Zero tokens: it fetches subscribed PRs, diffs
# them, holds wake lines for a settle window, then appends them to the events
# file of each subscribed session, where `bbw wait` picks them up.

daemon_log() { printf '%s %s\n' "$(bbw_iso)" "$1" >>"$(bbw_state_dir)/daemon.log"; }

# daemon_alive — the heartbeat is younger than three poll intervals.
daemon_alive() {
  local hb
  hb="$(bbw_state_dir)/heartbeat"
  [ -f "$hb" ] || return 1
  [ $(( $(bbw_now) - $(cat "$hb") )) -le $(( 3 * ${BBW_POLL_SECONDS:-60} )) ]
}

snapshot_path() { printf '%s/snapshots/%s__%s.json\n' "$(bbw_state_dir)" "$(printf '%s' "$1" | sed 's#/#__#g')" "$2"; }
pending_path() { printf '%s/pending/%s\n' "$(bbw_state_dir)" "$(safe_name "$1")"; }

# daemon_hold SESSION NOW URGENT TEXT — queue one wake line for SESSION.
daemon_hold() {
  local p; p="$(pending_path "$1")"
  mkdir -p "$(dirname "$p")"
  jq -cn --argjson ts "$2" --argjson urgent "$3" --arg text "$4" '{ts: $ts, urgent: $urgent, text: $text}' >>"$p.jsonl"
  printf '%s\n' "$2" >"$p.last"
}

# daemon_release NOW [FORCE_SESSION...] — move queued lines to the events file
# when one is urgent, when the queue has been quiet for BBW_SETTLE_SECONDS, or
# when the session is named in FORCE (its subscription just closed).
daemon_release() {
  local now="$1" f session last force; shift
  for f in "$(bbw_state_dir)/pending"/*.jsonl; do
    [ -f "$f" ] || continue
    session="$(basename "$f" .jsonl)"
    last="$(cat "${f%.jsonl}.last" 2>/dev/null || echo 0)"
    force=0
    for s in "$@"; do [ "$(safe_name "$s")" = "$session" ] && force=1; done
    if [ "$force" = 1 ] || jq -e 'select(.urgent)' "$f" >/dev/null 2>&1 \
      || [ $((now - last)) -ge "${BBW_SETTLE_SECONDS:-30}" ]; then
      events_append "$session" "$(jq -c '{ts, text}' "$f")" || continue
      rm -f "$f" "${f%.jsonl}.last"
    fi
  done
}

# daemon_resolve_pending NOW — look up the PR of each pending branch.
daemon_resolve_pending() {
  local now="$1" line repo branch session harness since pr
  store_subscriptions_jq -r '.[] | select(.status == "pending")
    | [.repo, .branch, .session, .harness, (.pending_since // 0 | tostring)] | @tsv' \
  | while IFS="$(printf '\t')" read -r repo branch session harness since; do
      if [ $((now - since)) -gt 86400 ]; then
        store_update_jq 'map(select((.status == "pending" and .repo == $r and .branch == $b and .session == $s) | not))' \
          --arg r "$repo" --arg b "$branch" --arg s "$session"
        daemon_log "pending $repo@$branch for $session given up after 24 h"
        continue
      fi
      pr="$(pr_for_branch "$repo" "$branch" 2>/dev/null)"
      [ -n "$pr" ] || continue
      cmd_subscribe "$repo" "$pr" --branch "$branch" --session "$session" --harness "$harness" >/dev/null \
        && daemon_log "pending $repo@$branch resolved to #$pr for $session"
    done
}

# daemon_once — one poll cycle over every open subscription.
daemon_once() {
  local now root pairs repo pr snap tmp rc sub session lines closed="" state
  now="$(bbw_now)"
  root="$(bbw_state_dir)"
  mkdir -p "$root/snapshots"
  if ! bbw_load_credentials 2>/dev/null; then
    daemon_log "credential missing: run bbw setup"
    return 1
  fi
  daemon_resolve_pending "$now"

  pairs="$(store_subscriptions_jq -r '[.[] | select(.status == "open") | "\(.repo) \(.pr)"] | unique[]')"
  while read -r repo pr; do
    [ -n "$repo" ] || continue
    snap="$(snapshot_path "$repo" "$pr")"
    tmp="$snap.new"
    snapshot_fetch "$repo" "$pr" "$snap" >"$tmp" 2>/dev/null; rc=$?
    if [ "$rc" = 10 ]; then
      daemon_log "auth error: credential rejected"
      rm -f "$tmp"
      break
    elif [ "$rc" != 0 ]; then
      daemon_log "fetch error $repo#$pr (code $rc)"
      rm -f "$tmp"
      continue
    fi

    while IFS= read -r sub; do
      session="$(printf '%s' "$sub" | jq -r '.session')"
      lines="$(diff_snapshots "$snap" "$tmp" "$sub")"
      [ -n "$lines" ] || continue
      printf '%s\n' "$lines" | jq -r 'select(.wake | not) | .text' | while IFS= read -r t; do daemon_log "$t"; done
      printf '%s\n' "$lines" | jq -c 'select(.wake)' | while IFS= read -r l; do
        daemon_hold "$session" "$now" "$(printf '%s' "$l" | jq '.urgent')" "$(printf '%s' "$l" | jq -r '.text')"
        daemon_log "$(printf '%s' "$l" | jq -r '.text') -> $session"
      done
    done <<EOF
$(store_subscriptions_jq -c '.[] | select(.status == "open" and .repo == $r and .pr == $p)' --arg r "$repo" --argjson p "$pr")
EOF

    state="$(jq -r '.state' "$tmp")"
    mv "$tmp" "$snap"
    case "$state" in
      MERGED|DECLINED|SUPERSEDED)
        closed="$closed $(store_subscriptions_jq -r '.[] | select(.status == "open" and .repo == $r and .pr == $p) | .session' --arg r "$repo" --argjson p "$pr" | tr '\n' ' ')"
        store_update_jq 'map(if .status == "open" and .repo == $r and .pr == $p then .status = "closed" else . end)' \
          --arg r "$repo" --argjson p "$pr"
        daemon_log "$repo#$pr ${state} — subscriptions closed"
        ;;
    esac
  done <<EOF
$pairs
EOF

  # shellcheck disable=SC2086
  daemon_release "$now" $closed
  printf '%s\n' "$now" >"$root/heartbeat"
}

# daemon_any_running — some subscribed PR has a status still in progress.
daemon_any_running() {
  local f
  for f in "$(bbw_state_dir)/snapshots"/*.json; do
    [ -f "$f" ] || continue
    jq -e '.state == "OPEN" and any(.statuses[]?; .state == "INPROGRESS")' "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

daemon_run() {
  local pidfile pid
  pidfile="$(bbw_state_dir)/daemon.pid"
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "already running (pid $pid)"
      return 1
    fi
  fi
  printf '%s\n' "$$" >"$pidfile"
  trap 'rm -f "$pidfile"; exit 0' INT TERM
  daemon_log "daemon started (pid $$)"
  while :; do
    daemon_once || true
    if daemon_any_running; then sleep "${BBW_FAST_POLL_SECONDS:-20}"; else sleep "${BBW_POLL_SECONDS:-60}"; fi
  done
}

LAUNCHD_LABEL="com.bitbucket-pr-watch.daemon"

daemon_plist_path() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$LAUNCHD_LABEL"; }

daemon_start() {
  local plist root
  if [ "$(uname -s)" != "Darwin" ] || ! command -v launchctl >/dev/null 2>&1; then
    echo "launchd not available: run 'nohup bbw daemon run &'"
    return 2
  fi
  root="$(bbw_state_dir)"
  plist="$(daemon_plist_path)"
  mkdir -p "$(dirname "$plist")"
  sed -e "s|@BBW@|$BBW_SELF|g" -e "s|@STATE@|$root|g" -e "s|@HOME@|$HOME|g" \
    "$BBW_TEMPLATES/$LAUNCHD_LABEL.plist" >"$plist"
  launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" && echo "daemon started ($plist)"
}

daemon_stop() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null && echo "daemon stopped"
    rm -f "$(daemon_plist_path)"
  fi
}

cmd_daemon() {
  case "${1:-}" in
    run) daemon_run ;;
    once) daemon_once ;;
    start) daemon_start ;;
    stop) daemon_stop ;;
    *) echo "bbw daemon run|once|start|stop" >&2; return 64 ;;
  esac
}
