#!/usr/bin/env bash
# store.sh — subscriptions, the lock that guards them, and per-session events.
#
# subscriptions.json is an array of
#   {repo, pr|null, branch|null, session, harness, since, own_heads[],
#    ignored_comments[], status: "pending"|"open"|"closed", pending_since}
# keyed by (repo, pr, session) once open, (repo, branch, session) while pending.

store_file() { printf '%s/subscriptions.json\n' "$(bbw_state_dir)"; }

# safe_name TEXT — a file-name-safe form of a session id.
safe_name() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'; }

# store_lock / store_unlock — mkdir is atomic on every filesystem we target.
# A lock older than 10 s belongs to a dead process and is broken.
store_lock() {
  local lock tries=0 age
  lock="$(bbw_state_dir)/.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || date +%s) ))
      if [ "$age" -gt 10 ]; then rmdir "$lock" 2>/dev/null; tries=0; continue; fi
      echo "bbw: state lock busy: $lock" >&2
      return 1
    fi
    sleep 0.1
  done
}
store_unlock() { rmdir "$(bbw_state_dir)/.lock" 2>/dev/null || true; }

# store_subscriptions_jq FILTER [JQ_ARGS...] — read the subscriptions.
store_subscriptions_jq() {
  local f filter="$1"; shift
  f="$(store_file)"
  [ -f "$f" ] || printf '[]' >"$f"
  jq "$@" "$filter" "$f"
}

# store_update_jq FILTER [JQ_ARGS...] — rewrite the subscriptions atomically.
store_update_jq() {
  local f filter="$1" rc; shift
  f="$(store_file)"
  store_lock || return 1
  [ -f "$f" ] || printf '[]' >"$f"
  jq "$@" "$filter" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  rc=$?
  store_unlock
  return "$rc"
}

events_file() { printf '%s/events/%s.jsonl\n' "$(bbw_state_dir)" "$(safe_name "$1")"; }
cursor_file() { printf '%s/events/%s.cursor\n' "$(bbw_state_dir)" "$(safe_name "$1")"; }

# events_append SESSION JSONL_LINES
events_append() {
  local f; f="$(events_file "$1")"
  mkdir -p "$(dirname "$f")"
  store_lock || return 1
  printf '%s\n' "$2" >>"$f"
  store_unlock
}

# events_unread SESSION — lines after the cursor.
events_unread() {
  local f c n=0
  f="$(events_file "$1")"; c="$(cursor_file "$1")"
  [ -f "$f" ] || return 0
  [ -f "$c" ] && n="$(cat "$c")"
  tail -n +"$((n + 1))" "$f"
}

# events_ack SESSION N — advance the cursor by N lines.
events_ack() {
  local c n=0
  c="$(cursor_file "$1")"
  mkdir -p "$(dirname "$c")"
  [ -f "$c" ] && n="$(cat "$c")"
  printf '%s\n' "$((n + $2))" >"$c.tmp" && mv "$c.tmp" "$c"
}

# urlencode TEXT — percent-encode everything but unreserved characters.
urlencode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in [A-Za-z0-9._~-]) out="$out$c" ;; *) out="$out$(printf '%%%02X' "'$c")" ;; esac
  done
  printf '%s' "$out"
}

# repo_from_remote [DIR] — WS/REPO from the origin remote of a Bitbucket clone.
repo_from_remote() {
  local url
  url="$(git -C "${1:-.}" remote get-url origin 2>/dev/null)" || return 1
  printf '%s' "$url" | sed -nE 's#.*bitbucket\.org[:/]([^/]+)/([^/]+)$#\1/\2#p' | sed 's/\.git$//'
}

# pr_for_branch WS/REPO BRANCH — print the open PR id, or nothing.
# Returns bb_get's code when the lookup itself fails.
pr_for_branch() {
  local q body
  q="$(urlencode "source.branch.name=\"$2\" AND state=\"OPEN\"")"
  body="$(bb_get "repositories/$1/pullrequests?q=$q")" || return $?
  printf '%s' "$body" | jq -r '.values[0].id // empty'
}

cmd_subscribe() {
  local repo="" pr="" branch="" session="" harness="cli" head=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branch="$2"; shift ;;
      --repo) repo="$2"; shift ;;
      --session) session="$2"; shift ;;
      --harness) harness="$2"; shift ;;
      --head) head="$2"; shift ;;
      -*) echo "bbw subscribe: unknown option $1" >&2; return 64 ;;
      *) if [ -z "$repo" ]; then repo="$1"; else pr="$1"; fi ;;
    esac
    shift
  done
  [ -n "$session" ] || { echo "bbw subscribe: --session is required" >&2; return 64; }
  [ -n "$repo" ] || repo="$(repo_from_remote)"
  [ -n "$repo" ] || { echo "bbw subscribe: no Bitbucket origin remote here; pass --repo WS/REPO" >&2; return 1; }
  if [ -z "$pr" ]; then
    [ -n "$branch" ] || { echo "bbw subscribe: give a PR number or --branch" >&2; return 64; }
    bbw_load_credentials || return 1
    pr="$(pr_for_branch "$repo" "$branch")"
  fi
  case "$pr" in ''|*[!0-9]*) pr="" ;; esac

  if [ -n "$pr" ]; then
    store_update_jq '
      ([.[] | select(.repo == $repo and .pr == null and .branch == $branch and .session == $session and $branch != "")]
        | map(.own_heads) | add // []) as $carried
      | map(select((.repo == $repo and .pr == null and .branch == $branch and .session == $session and $branch != "") | not))
      | if any(.[]; .repo == $repo and .pr == $pr and .session == $session) then
          map(if .repo == $repo and .pr == $pr and .session == $session
              then .own_heads = ((.own_heads + $carried + [$head | select(. != "")]) | unique_by(.) ) | .status = "open"
              else . end)
        else . + [{repo: $repo, pr: $pr, branch: (if $branch == "" then null else $branch end),
                   session: $session, harness: $harness, since: $now, status: "open",
                   own_heads: (($carried + [$head | select(. != "")]) | unique_by(.)), ignored_comments: []}]
        end' \
      --arg repo "$repo" --argjson pr "$pr" --arg branch "$branch" --arg session "$session" \
      --arg harness "$harness" --arg head "$head" --arg now "$(bbw_iso)" || return 1
    echo "subscribed $repo#$pr"
  else
    store_update_jq '
      if any(.[]; .repo == $repo and .pr == null and .branch == $branch and .session == $session) then
        map(if .repo == $repo and .pr == null and .branch == $branch and .session == $session
            then .own_heads = ((.own_heads + [$head | select(. != "")]) | unique_by(.)) else . end)
      else . + [{repo: $repo, pr: null, branch: $branch, session: $session, harness: $harness,
                 since: $now, pending_since: $epoch, status: "pending",
                 own_heads: [$head | select(. != "")], ignored_comments: []}]
      end' \
      --arg repo "$repo" --arg branch "$branch" --arg session "$session" --arg harness "$harness" \
      --arg head "$head" --arg now "$(bbw_iso)" --argjson epoch "$(bbw_now)" || return 1
    echo "pending $repo@$branch"
  fi
}

cmd_unsubscribe() {
  local repo="$1" pr="$2" session=""
  [ "${3:-}" = "--session" ] && session="${4:-}"
  [ -n "$session" ] || { echo "bbw unsubscribe: WS/REPO PR --session ID" >&2; return 64; }
  store_update_jq 'map(select((.repo == $repo and .pr == $pr and .session == $session) | not))' \
    --arg repo "$repo" --argjson pr "$pr" --arg session "$session"
}

cmd_ignore_comment() {
  local repo="$1" pr="$2" id="$3" session=""
  [ "${4:-}" = "--session" ] && session="${5:-}"
  [ -n "$session" ] || { echo "bbw ignore-comment: WS/REPO PR COMMENT_ID --session ID" >&2; return 64; }
  store_update_jq 'map(if .repo == $repo and .pr == $pr and .session == $session
                       then .ignored_comments = ((.ignored_comments + [$id]) | unique) else . end)' \
    --arg repo "$repo" --argjson pr "$pr" --arg id "$id" --arg session "$session"
}

cmd_list() {
  local session=""
  [ "${1:-}" = "--session" ] && session="${2:-}"
  store_subscriptions_jq -r '.[] | select(.status != "closed") | select($s == "" or .session == $s)
    | if .pr == null then "\(.repo)@\(.branch) pending \(.session)" else "\(.repo)#\(.pr) \(.status) \(.session)" end' \
    --arg s "$session"
}
