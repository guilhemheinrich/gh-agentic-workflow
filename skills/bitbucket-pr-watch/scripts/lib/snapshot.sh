#!/usr/bin/env bash
# snapshot.sh — fetch a PR and reduce it to the fields whose change can wake
# a session. Comment bodies are never kept: they are third-party text.

# snapshot_fetch WS/REPO PR [PREV_SNAPSHOT_FILE] — print the snapshot JSON.
# Returns bb_get's code on the first failed call.
snapshot_fetch() {
  local repo="$1" pr="$2" prev="${3:-}" base t rc head dest url conflict
  base="repositories/$repo"
  t="$(mktemp -d)"

  bb_get "$base/pullrequests/$pr" >"$t/pr" || { rc=$?; rm -rf "$t"; return "$rc"; }
  head="$(jq -r '.source.commit.hash' "$t/pr")"
  dest="$(jq -r '.destination.commit.hash' "$t/pr")"

  bb_get "$base/commit/$head/statuses?pagelen=100" >"$t/statuses" || { rc=$?; rm -rf "$t"; return "$rc"; }

  : >"$t/comments"
  url="$base/pullrequests/$pr/comments?pagelen=100"
  while [ -n "$url" ]; do
    bb_get "$url" >"$t/page" || { rc=$?; rm -rf "$t"; return "$rc"; }
    jq -c '.values[]?' "$t/page" >>"$t/comments"
    url="$(jq -r '.next // empty' "$t/page")"
  done

  # The diffstat is the heaviest call: only when one of the heads moved.
  if [ -n "$prev" ] && [ -f "$prev" ] \
    && [ "$(jq -r '.head + " " + .dest_head' "$prev")" = "$head $dest" ]; then
    conflict="$(jq '.conflict' "$prev")"
  else
    bb_get "$base/pullrequests/$pr/diffstat?pagelen=500" >"$t/diffstat" || { rc=$?; rm -rf "$t"; return "$rc"; }
    conflict="$(jq '[.values[]? | select(.status == "merge conflict")] | length > 0' "$t/diffstat")"
  fi

  jq -n --arg repo "$repo" --argjson pr "$pr" --argjson conflict "$conflict" --arg now "$(bbw_iso)" \
    --slurpfile p "$t/pr" --slurpfile s "$t/statuses" --slurpfile c <(jq -s '.' "$t/comments") '
    ($p[0]) as $pr_ | {
      repo: $repo, pr: $pr, state: $pr_.state,
      head: $pr_.source.commit.hash, dest_head: $pr_.destination.commit.hash,
      title: $pr_.title, url: $pr_.links.html.href,
      participants: ([$pr_.participants[]?
        | {key: .user.account_id,
           value: {name: .user.display_name,
                   state: (if .approved then "approved" elif .state == "changes_requested" then "changes_requested" else null end)}}
        | select(.value.state != null)] | from_entries),
      statuses: ([$s[0].values[]? | {key: .key, value: {name: .name, state: .state}}] | from_entries),
      comments: ([$c[0][] | {key: (.id | tostring),
                   value: {author: .user.display_name, path: (.inline.path // null),
                           line: (.inline.to // .inline.from // null), deleted: (.deleted // false)}}] | from_entries),
      conflict: $conflict, fetched_at: $now }'
  rc=$?
  rm -rf "$t"
  return "$rc"
}
