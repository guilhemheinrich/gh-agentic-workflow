#!/usr/bin/env bash
# bitbucket.sh — Bitbucket Cloud: the requests and the snapshots of a PR and of
# a commit's build. Comment bodies are never kept: they are third-party text.
# Keys are "WS/REPO" (see provider.sh).

# bitbucket_repo_from_url URL — WS/REPO of a Bitbucket remote URL, else nothing.
bitbucket_repo_from_url() {
  printf '%s' "$1" | sed -nE 's#.*bitbucket\.org[:/]([^/]+)/([^/]+)$#\1/\2#p' | sed 's/\.git$//'
}

# bitbucket_check_credential — the credential is loaded, or say how to fix it.
bitbucket_check_credential() { prw_load_credentials; }

# bitbucket_pr_for_branch KEY BRANCH — the open PR id, or nothing. Returns
# bb_get's code when the lookup itself fails.
bitbucket_pr_for_branch() {
  local repo q body
  repo="$(repo_of "$1")"
  q="$(urlencode "source.branch.name=\"$2\" AND state=\"OPEN\"")"
  body="$(bb_get "repositories/$repo/pullrequests?q=$q")" || return $?
  printf '%s' "$body" | jq -r '.values[0].id // empty'
}

# bitbucket_pr_merge_commit KEY PR — the merge commit hash of a PR, or nothing.
bitbucket_pr_merge_commit() {
  bb_get "repositories/$(repo_of "$1")/pullrequests/$2" 2>/dev/null | jq -r '.merge_commit.hash // empty'
}

# bitbucket_snapshot_fetch KEY PR [PREV_SNAPSHOT_FILE] — print the snapshot
# JSON. Returns bb_get's code on the first failed call.
bitbucket_snapshot_fetch() {
  local key="$1" pr="$2" prev="${3:-}" repo base t rc head dest url conflict
  repo="$(repo_of "$key")"
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

  jq -n --arg repo "$key" --argjson pr "$pr" --argjson conflict "$conflict" --arg now "$(prw_iso)" \
    --slurpfile p "$t/pr" --slurpfile s "$t/statuses" --slurpfile c <(jq -s '.' "$t/comments") '
    ($p[0]) as $pr_ | {
      repo: $repo, pr: $pr, state: $pr_.state,
      head: $pr_.source.commit.hash, dest_head: $pr_.destination.commit.hash,
      dest_branch: ($pr_.destination.branch.name // null), merge_commit: ($pr_.merge_commit.hash // null),
      title: $pr_.title, url: $pr_.links.html.href,
      participants: ([$pr_.participants[]?
        | {key: .user.account_id,
           value: {name: .user.display_name,
                   state: (if .approved then "approved" elif .state == "changes_requested" then "changes_requested" else null end)}}
        | select(.value.state != null)] | from_entries),
      statuses: ([$s[0].values[]? | {key: .key, value: {name: .name, state: .state, updated: (.updated_on // null)}}] | from_entries),
      comments: ([$c[0][] | {key: (.id | tostring),
                   value: {author: .user.display_name, path: (.inline.path // null),
                           line: (.inline.to // .inline.from // null), deleted: (.deleted // false)}}] | from_entries),
      conflict: $conflict, fetched_at: $now }'
  rc=$?
  rm -rf "$t"
  return "$rc"
}

# bitbucket_build_fetch KEY COMMIT [PR_SNAPSHOT_FILE] — the build snapshot of one
# commit: the statuses Bitbucket Pipelines and external builds report on it.
# A fast-forward merge keeps the PR head as the merge commit: a status the PR
# phase already saw there, same key and same updated_on, is the finished PR
# pipeline and must not pass for the branch pipeline, so it is dropped.
bitbucket_build_fetch() {
  local key="$1" commit="$2" prsnap="${3:-}" repo t rc
  repo="$(repo_of "$key")"
  t="$(mktemp -d)"
  bb_get "repositories/$repo/commit/$commit/statuses?pagelen=100" >"$t/s" || { rc=$?; rm -rf "$t"; return "$rc"; }
  if [ -n "$prsnap" ] && [ -f "$prsnap" ]; then cp "$prsnap" "$t/p"; else printf '{}' >"$t/p"; fi
  jq -n --arg repo "$key" --arg commit "$commit" --arg now "$(prw_iso)" \
    --slurpfile s "$t/s" --slurpfile p "$t/p" '
    ($p[0]) as $p | ($p.head // "") as $h
    | ($h != "" and (($h | startswith($commit)) or ($commit | startswith($h)))) as $same
    | {repo: $repo, commit: $commit, phase: "build",
       statuses: ([$s[0].values[]?
         | select(($same and .updated_on != null and ($p.statuses[.key].updated // null) == .updated_on) | not)
         | {key: .key, value: {name: .name, state: .state, url: (.url // null)}}] | from_entries),
       fetched_at: $now}'
  rc=$?
  rm -rf "$t"
  return "$rc"
}
