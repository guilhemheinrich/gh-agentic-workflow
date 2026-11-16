#!/usr/bin/env bash
# daemon.sh — the poll loop. Zero tokens: it fetches subscribed PRs, diffs
# them, holds wake lines for a settle window, then appends them to the events
# file of each subscribed session, where `prw wait` picks them up.

daemon_log() { printf '%s %s\n' "$(prw_iso)" "$1" >>"$(prw_state_dir)/daemon.log"; }

# daemon_alive — the heartbeat is younger than three poll intervals.
daemon_alive() {
  local hb
  hb="$(prw_state_path)/heartbeat"
  [ -f "$hb" ] || return 1
  [ $(( $(prw_now) - $(cat "$hb") )) -le $(( 3 * ${PRW_POLL_SECONDS:-60} )) ]
}

snapshot_path() { printf '%s/snapshots/%s__%s.json\n' "$(prw_state_dir)" "$(printf '%s' "$1" | sed 's#/#__#g')" "$2"; }
pending_path() { printf '%s/pending/%s\n' "$(prw_state_dir)" "$(safe_name "$1")"; }

# daemon_fetch_error RC LABEL SNAPSHOT — log one failed fetch with its HTTP
# code and URL, and count it next to SNAPSHOT (SNAPSHOT.err) for doctor; a
# success removes the count. Returns 1 when the credential itself is
# rejected (401): every other call would fail too.
daemon_fetch_error() {
  local rc="$1" label="$2" err="$3.err" n url
  n="$(jq -r '.count // 0' "$err" 2>/dev/null)" || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  url="${HTTP_URL:-}"; url="${url#"$BITBUCKET_API_BASE"/}"; url="${url#"$GITHUB_API_BASE"/}"
  jq -cn --argjson n "$((n + 1))" --argjson rc "$rc" --arg http "${HTTP_CODE:-}" \
    --arg url "$url" --arg at "$(prw_iso)" \
    '{count: $n, code: $rc, http: $http, url: $url, last: $at}' >"$err"
  case "$rc" in
    10) daemon_log "auth error: credential rejected"; return 1 ;;
    14) daemon_log "no access to $label (403)" ;;
    *) daemon_log "fetch error $label (code $rc, HTTP ${HTTP_CODE:-?} on $url)" ;;
  esac
  return 0
}

# daemon_diff_all REPO PR OLD NEW — the transition lines of every open
# subscription on REPO#PR, each tagged with its session, as JSONL on stdout.
# On the first failed diff: log jq's own message, count it next to OLD
# (OLD.differr) for doctor, and return 1 with nothing usable printed.
daemon_diff_all() {
  local repo="$1" pr="$2" old="$3" new="$4" sub session lines errf msg n
  errf="$old.differr.msg"
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    session="$(printf '%s' "$sub" | jq -r '.session')"
    if ! lines="$(diff_snapshots "$old" "$new" "$sub" 2>"$errf")"; then
      msg="$(tr '\n' ' ' <"$errf" | cut -c1-300)"
      rm -f "$errf"
      n="$(jq -r '.count // 0' "$old.differr" 2>/dev/null)" || n=0
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      jq -cn --argjson n "$((n + 1))" --arg msg "$msg" --arg at "$(prw_iso)" \
        '{count: $n, msg: $msg, last: $at}' >"$old.differr"
      daemon_log "diff error $repo#$pr (snapshot kept, retried next cycle): $msg"
      return 1
    fi
    [ -n "$lines" ] && printf '%s\n' "$lines" | jq -c --arg s "$session" '. + {session: $s}'
  done <<EOF
$(store_subscriptions_jq -c '.[] | select(.status == "open" and .repo == $r and .pr == $p)' --arg r "$repo" --argjson p "$pr")
EOF
  rm -f "$errf"
  return 0
}

# daemon_hold SESSION NOW URGENT TEXT — queue one wake line for SESSION.
daemon_hold() {
  local p; p="$(pending_path "$1")"
  mkdir -p "$(dirname "$p")"
  jq -cn --argjson ts "$2" --argjson urgent "$3" --arg text "$4" '{ts: $ts, urgent: $urgent, text: $text}' >>"$p.jsonl"
  printf '%s\n' "$2" >"$p.last"
}

# daemon_release NOW [FORCE_SESSION...] — move queued lines to the events file
# when one is urgent, when the queue has been quiet for PRW_SETTLE_SECONDS, or
# when the session is named in FORCE (its subscription just closed).
daemon_release() {
  local now="$1" f session last force; shift
  for f in "$(prw_state_dir)/pending"/*.jsonl; do
    [ -f "$f" ] || continue
    session="$(basename "$f" .jsonl)"
    last="$(cat "${f%.jsonl}.last" 2>/dev/null || echo 0)"
    force=0
    for s in "$@"; do [ "$(safe_name "$s")" = "$session" ] && force=1; done
    if [ "$force" = 1 ] || jq -e 'select(.urgent)' "$f" >/dev/null 2>&1 \
      || [ $((now - last)) -ge "${PRW_SETTLE_SECONDS:-30}" ]; then
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
      case $? in
        0) ;;
        10) daemon_log "auth error: credential rejected"; continue ;;
        *) daemon_log "branch lookup error $repo@$branch"; continue ;;
      esac
      [ -n "$pr" ] || continue
      cmd_subscribe "$repo" "$pr" --branch "$branch" --session "$session" --harness "$harness" >/dev/null \
        && daemon_log "pending $repo@$branch resolved to #$pr for $session"
    done
}

# daemon_once — one poll cycle over every open subscription.
daemon_once() {
  local now root pairs repo pr snap tmp rc sub session lines closed="" state mc db authfail=""
  now="$(prw_now)"
  root="$(prw_state_dir)"
  mkdir -p "$root/snapshots"
  # The heartbeat says "the daemon runs", not "the credential works": doctor
  # checks the credential separately, and a missing beat would make every
  # SessionStart restart a daemon that is only waiting for `prw setup`.
  printf '%s\n' "$now" >"$root/heartbeat"
  prw_source_credentials
  if [ -z "${BITBUCKET_WATCH_TOKEN:-}" ] && [ -z "$(github_tokens)" ]; then
    daemon_log "credential missing: run prw setup"
    return 1
  fi
  daemon_resolve_pending "$now"

  pairs="$(store_subscriptions_jq -r '[.[] | select(.status == "open") | "\(.repo) \(.pr)"] | unique[]')"
  while read -r repo pr; do
    [ -n "$repo" ] || continue
    # A host whose credential was rejected this cycle is not called again.
    case " $authfail " in *" $(provider_of "$repo") "*) continue ;; esac
    case " $authfail " in *" $(provider_of "$repo") "*) continue ;; esac
    snap="$(snapshot_path "$repo" "$pr")"
    tmp="$snap.new"
    HTTP_CODE="" HTTP_URL=""
    snapshot_fetch "$repo" "$pr" "$snap" >"$tmp" 2>/dev/null; rc=$?
    if [ "$rc" != 0 ]; then
      # 403 on one repo does not starve the others; 401 stops the cycle.
      rm -f "$tmp"
      daemon_fetch_error "$rc" "$repo#$pr" "$snap" || { authfail="$authfail $(provider_of "$repo")"; continue; }
      continue
    fi
    rm -f "$snap.err"

    # Diff for every subscriber first, act only if all diffs succeeded. A
    # failed diff must not advance the snapshot: on 2026-11-02 a jq 1.7
    # parse difference failed every diff, the snapshot moved on anyway, and
    # each comment and pipeline end was consumed without waking anyone.
    if ! daemon_diff_all "$repo" "$pr" "$snap" "$tmp" >"$snap.lines"; then
      rm -f "$tmp" "$snap.lines"
      continue
    fi
    rm -f "$snap.differr"
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      session="$(printf '%s' "$l" | jq -r '.session')"
      if [ "$(printf '%s' "$l" | jq '.wake')" = true ]; then
        daemon_hold "$session" "$now" "$(printf '%s' "$l" | jq '.urgent')" "$(printf '%s' "$l" | jq -r '.text')"
        daemon_log "$(printf '%s' "$l" | jq -r '.text') -> $session"
      else
        daemon_log "$(printf '%s' "$l" | jq -r '.text')"
      fi
    done <"$snap.lines"
    rm -f "$snap.lines"

    state="$(jq -r '.state' "$tmp")"
    mv "$tmp" "$snap"
    case "$state" in
      MERGED|DECLINED|SUPERSEDED)
        closed="$closed $(store_subscriptions_jq -r '.[] | select(.status == "open" and .repo == $r and .pr == $p) | .session' --arg r "$repo" --argjson p "$pr" | tr '\n' ' ')"
        ;;
    esac
    case "$state" in
      MERGED)
        # The pipeline Bitbucket runs on the destination branch is the one
        # that deploys: follow the merge commit until it ends.
        mc="$(jq -r '.merge_commit // empty' "$snap")"
        db="$(jq -r '.dest_branch // empty' "$snap")"
        store_update_jq 'map(if .status == "open" and .repo == $r and .pr == $p
            then .status = "build" | .origin = "merge" | .build_since = $now
                 | .commit = (if $c == "" then null else $c end) | .build_branch = $b
            else . end)' \
          --arg r "$repo" --argjson p "$pr" --arg c "$mc" --arg b "$db" --argjson now "$now"
        daemon_log "$repo#$pr MERGED — following merge commit ${mc:-(not known yet)} on ${db:-?}"
        ;;
      DECLINED|SUPERSEDED)
        store_update_jq 'map(if .status == "open" and .repo == $r and .pr == $p then .status = "closed" else . end)' \
          --arg r "$repo" --argjson p "$pr"
        daemon_log "$repo#$pr ${state} — subscriptions closed"
        ;;
    esac
  done <<EOF
$pairs
EOF

  PRW_BUILD_CLOSED=""
  daemon_builds "$now"

  # shellcheck disable=SC2086
  daemon_release "$now" $closed $PRW_BUILD_CLOSED
  printf '%s\n' "$now" >"$root/heartbeat"
}

# daemon_builds NOW — poll every followed commit (a merge commit after MERGED,
# or a pushed commit from `prw subscribe --commit`) and close each build-phase
# subscription whose verdict is in. Appends to PRW_BUILD_CLOSED the sessions
# whose wake line must be released in this cycle.
daemon_builds() {
  local now="$1" targets repo commit pr snap tmp rc sub session v prsnap
  targets="$(store_subscriptions_jq -r '[.[] | select(.status == "build") | "\(.repo) \(.commit // "-") \(.pr // "-")"] | unique[]')"
  while read -r repo commit pr; do
    [ -n "$repo" ] || continue
    case " $authfail " in *" $(provider_of "$repo") "*) continue ;; esac
    case " $authfail " in *" $(provider_of "$repo") "*) continue ;; esac
    if [ "$commit" = "-" ] && [ "$pr" != "-" ]; then
      # MERGED without merge_commit yet: ask the PR again.
      commit="$(pr_merge_commit "$repo" "$pr" 2>/dev/null)"
      if [ -n "$commit" ]; then
        store_update_jq 'map(if .status == "build" and .repo == $r and .pr == $p and .commit == null then .commit = $c else . end)' \
          --arg r "$repo" --argjson p "$pr" --arg c "$commit"
      else
        commit="-"
      fi
    fi
    if [ "$commit" = "-" ]; then
      # No commit to follow: only the "no pipeline" timeout can end it.
      snap="$(snapshot_path "$repo" "pr-$pr-merge")"
      printf '%s\n' '{"statuses":{}}' >"$snap"
    else
      snap="$(snapshot_path "$repo" "commit-$commit")"
      tmp="$snap.new"
      prsnap=""
      [ "$pr" != "-" ] && prsnap="$(snapshot_path "$repo" "$pr")"
      HTTP_CODE="" HTTP_URL=""
      build_fetch "$repo" "$commit" "$prsnap" >"$tmp" 2>/dev/null; rc=$?
      if [ "$rc" != 0 ]; then
        rm -f "$tmp"
        daemon_fetch_error "$rc" "$repo@$commit" "$snap" || { authfail="$authfail $(provider_of "$repo")"; continue; }
        continue
      fi
      rm -f "$snap.err"
      build_transitions "$snap" "$tmp" | while IFS= read -r t; do daemon_log "$t"; done
      mv "$tmp" "$snap"
    fi

    while IFS= read -r sub; do
      [ -n "$sub" ] || continue
      v="$(build_verdict "$snap" "$sub" "$now")"
      [ -n "$v" ] || continue
      session="$(printf '%s' "$sub" | jq -r '.session')"
      daemon_hold "$session" "$now" "$(printf '%s' "$v" | jq '.urgent')" "$(printf '%s' "$v" | jq -r '.text')"
      daemon_log "$(printf '%s' "$v" | jq -r '.text') -> $session"
      store_update_jq 'map(if .status == "build" and .repo == $r and .session == $s
          and (.commit // "-") == $c and (.pr // "-" | tostring) == $p then .status = "closed" else . end)' \
        --arg r "$repo" --arg s "$session" --arg c "$commit" --arg p "$pr"
      PRW_BUILD_CLOSED="$PRW_BUILD_CLOSED $session"
    done <<EOF
$(store_subscriptions_jq -c '.[] | select(.status == "build" and .repo == $r and (.commit // "-") == $c and (.pr // "-" | tostring) == $p)' --arg r "$repo" --arg c "$commit" --arg p "$pr")
EOF
    # Nobody follows this commit any more: drop its snapshot, so a build
    # closed while still running does not keep the fast poll on forever.
    if [ "$(store_subscriptions_jq '[.[] | select(.status == "build" and .repo == $r and (.commit // "-") == $c)] | length' --arg r "$repo" --arg c "$commit")" = 0 ]; then
      rm -f "$snap" "$snap.err"
    fi
  done <<EOF
$targets
EOF
}

# daemon_any_running — some subscribed PR has a status still in progress.
daemon_any_running() {
  local f
  for f in "$(prw_state_dir)/snapshots"/*.json; do
    [ -f "$f" ] || continue
    jq -e '(.state == "OPEN" or .phase == "build") and any(.statuses[]?; .state == "INPROGRESS")' "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# daemon_pid_is_ours PID — PID is alive AND runs `prw daemon run`. After a
# reboot the pidfile may name a PID reused by an unrelated process.
daemon_pid_is_ours() {
  local cmd
  kill -0 "$1" 2>/dev/null || return 1
  cmd="$(ps -p "$1" -o command= 2>/dev/null)"
  [ -n "$cmd" ] || cmd="$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)"
  case "$cmd" in *"daemon run"*) return 0 ;; esac
  return 1
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# daemon_scripts — the files a running daemon has sourced.
daemon_scripts() { printf '%s\n' "$(dirname "$PRW_LIB")/prw" "$PRW_LIB"/*.sh; }

# daemon_newer_script — print the first script modified after the daemon
# loaded its code (the daemon.started marker), if any.
daemon_newer_script() {
  local m f
  m="$(prw_state_dir)/daemon.started"
  [ -f "$m" ] && [ -n "${PRW_LIB:-}" ] || return 1
  while IFS= read -r f; do
    [ "$f" -nt "$m" ] && { printf '%s\n' "$f"; return 0; }
  done <<EOF
$(daemon_scripts)
EOF
  return 1
}

daemon_run() {
  local pidfile pid changed
  pidfile="$(prw_state_dir)/daemon.pid"
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    # Our own pid is a re-exec, not a second daemon.
    if [ -n "$pid" ] && [ "$pid" != "$$" ] && daemon_pid_is_ours "$pid"; then
      echo "already running (pid $pid)"
      return 1
    fi
  fi
  printf '%s\n' "$$" >"$pidfile"
  : >"$(prw_state_dir)/daemon.started"
  # launchd appends stderr to daemon.out forever: remember where this run's
  # output begins, so doctor reads only errors of the code now running.
  wc -c <"$(prw_state_dir)/daemon.out" 2>/dev/null | tr -d ' ' >"$(prw_state_dir)/daemon.out.offset" \
    || echo 0 >"$(prw_state_dir)/daemon.out.offset"
  # `sleep & wait` so TERM from launchd runs the trap at once instead of after
  # the sleep, and the pidfile does not go stale.
  trap 'rm -f "$pidfile"; exit 0' INT TERM
  daemon_log "daemon started (pid $$)"
  while :; do
    daemon_once || true
    if daemon_any_running; then sleep "${PRW_FAST_POLL_SECONDS:-20}" & else sleep "${PRW_POLL_SECONDS:-60}" & fi
    wait $!
    # A long-running bash never re-sources its libraries: after an update on
    # disk it would keep polling with the old code (2026-11-02: two hours of
    # 302s from a pre-fix api.sh). Replace the process with the new code.
    if changed="$(daemon_newer_script)"; then
      daemon_log "scripts changed on disk ($changed) — re-exec (pid $$)"
      exec "${BASH:-bash}" "$(dirname "$PRW_LIB")/prw" daemon run
    fi
  done
}

# daemon_out_errors — one line when the running daemon wrote an error to its
# launchd stderr (daemon.out): a jq or bash error there means code that fails
# outside every path the daemon logs itself.
daemon_out_errors() {
  local out off n last
  out="$(prw_state_dir)/daemon.out"
  [ -f "$out" ] || return 0
  off="$(cat "$(prw_state_dir)/daemon.out.offset" 2>/dev/null)"
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  n="$(tail -c +"$((off + 1))" "$out" | grep -ci 'error')"
  [ "${n:-0}" -gt 0 ] || return 0
  last="$(tail -c +"$((off + 1))" "$out" | grep -i 'error' | tail -1 | cut -c1-200)"
  echo "daemon.out: $n error line(s) since the daemon started, last: $last"
}

# daemon_health — one line per problem doctor must report: a target with
# repeated fetch errors, a subscription the daemon never snapshotted, or a
# daemon still running code older than the scripts on disk.
daemon_health() {
  local now poll repo key since snap f
  now="$(date -u +%s)"
  poll="${PRW_POLL_SECONDS:-60}"
  store_subscriptions_jq -r '.[]
      | select(.status == "open" or (.status == "build" and .commit != null))
      | if .status == "open" then [.repo, (.pr | tostring), (.since_epoch // 0 | tostring)]
        else [.repo, "commit-\(.commit)", (.build_since // 0 | tostring)] end
      | @tsv' | sort -u \
  | while IFS="$(printf '\t')" read -r repo key since; do
      snap="$(snapshot_path "$repo" "$key")"
      if [ -f "$snap.err" ] && [ "$(jq '.count' "$snap.err")" -ge "${PRW_DOCTOR_ERRORS:-3}" ]; then
        jq -r --arg t "$repo $key" '"\($t): \(.count) consecutive fetch errors (code \(.code), HTTP \(.http) on \(.url)), last \(.last)"' "$snap.err"
      elif [ -f "$snap.differr" ]; then
        jq -r --arg t "$repo $key" '"\($t): \(.count) failed diff(s), changes held back, last \(.last): \(.msg)"' "$snap.differr"
      elif [ ! -f "$snap" ] && [ $((now - since)) -gt $((3 * poll)) ]; then
        echo "$repo $key: no snapshot yet, subscribed $((now - since)) s ago"
      fi
    done
  daemon_out_errors
  # A change younger than three polls is the re-exec still to come.
  [ -f "$(prw_state_dir)/daemon.started" ] && [ -n "${PRW_LIB:-}" ] || return 0
  while IFS= read -r f; do
    if [ "$f" -nt "$(prw_state_dir)/daemon.started" ] && [ $((now - $(file_mtime "$f"))) -gt $((3 * poll)) ]; then
      echo "daemon runs code older than $f: prw daemon stop && prw daemon start"
      return 0
    fi
  done <<EOF
$(daemon_scripts)
EOF
}

LAUNCHD_LABEL="com.pr-watch.daemon"

daemon_plist_path() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$LAUNCHD_LABEL"; }

daemon_start() {
  local plist root
  prw_require_installed || return 1
  if [ "$(uname -s)" != "Darwin" ] || ! command -v launchctl >/dev/null 2>&1; then
    echo "launchd not available: run 'nohup prw daemon run &'"
    return 2
  fi
  root="$(prw_state_dir)"
  plist="$(daemon_plist_path)"
  mkdir -p "$(dirname "$plist")"
  sed -e "s|@PRW@|$PRW_SELF|g" -e "s|@STATE@|$root|g" -e "s|@HOME@|$HOME|g" \
    "$PRW_TEMPLATES/$LAUNCHD_LABEL.plist" >"$plist"
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
    alive) daemon_alive ;;
    start) daemon_start ;;
    stop) daemon_stop ;;
    *) echo "prw daemon run|once|alive|start|stop" >&2; return 64 ;;
  esac
}
