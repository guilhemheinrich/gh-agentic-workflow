#!/usr/bin/env bash
# github.sh — GitHub: the requests and the snapshots of a PR and of a commit's
# CI. Comment bodies are never kept: they are third-party text. Keys are
# "github:OWNER/REPO" (see provider.sh).
#
# GitHub reports a commit's CI in two shapes: check runs (GitHub Actions and
# GitHub Apps) and the legacy commit statuses (external CI). Both are reduced
# to the states the diff understands: SUCCESSFUL, FAILED, STOPPED, INPROGRESS.

# GITHUB_STATE_DEFS — jq definitions shared by the snapshot and the build phase.
GITHUB_STATE_DEFS='
def check_state:
  if .status != "completed" then "INPROGRESS"
  elif (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") then "SUCCESSFUL"
  elif .conclusion == "cancelled" then "STOPPED"
  else "FAILED" end;
def status_state:
  if .state == "success" then "SUCCESSFUL"
  elif .state == "pending" then "INPROGRESS"
  else "FAILED" end;
def ci_entries($checks; $statuses):
  ([$checks[] | {key: ("check:" + .name), value: {name: .name, state: check_state,
      updated: (.completed_at // .started_at // null), url: (.html_url // null)}}]
   + [$statuses[] | {key: ("status:" + .context), value: {name: .context, state: status_state,
      updated: (.updated_at // null), url: (.target_url // null)}}]);
'

# github_repo_from_url URL — github:OWNER/REPO of a GitHub remote URL, else nothing.
github_repo_from_url() {
  local path
  path="$(printf '%s' "$1" | sed -nE 's#.*github\.com[:/]([^/]+)/([^/]+)$#\1/\2#p' | sed 's/\.git$//')"
  [ -n "$path" ] && printf 'github:%s\n' "$path"
  return 0
}

# github_check_credential — the token is loaded, or say how to fix it.
github_check_credential() {
  prw_source_credentials
  if [ -z "${GITHUB_WATCH_TOKEN:-}" ]; then
    echo "GitHub credential missing: run prw setup --github" >&2
    return 1
  fi
}

# github_pr_for_branch KEY BRANCH — the open PR number, or nothing. GitHub
# filters the head by "owner:branch".
github_pr_for_branch() {
  local repo head body
  repo="$(repo_of "$1")"
  head="$(urlencode "${repo%%/*}:$2")"
  body="$(gh_get "repos/$repo/pulls?state=open&head=$head")" || return $?
  printf '%s' "$body" | jq -r '.[0].number // empty'
}

# github_pr_merge_commit KEY PR — the merge commit of a merged PR, or nothing.
github_pr_merge_commit() {
  gh_get "repos/$(repo_of "$1")/pulls/$2" 2>/dev/null \
    | jq -r 'if .merged then (.merge_commit_sha // empty) else empty end'
}

# github_snapshot_fetch KEY PR [PREV_SNAPSHOT_FILE] — print the snapshot JSON.
# Returns gh_get's code on the first failed call.
github_snapshot_fetch() {
  local key="$1" pr="$2" prev="${3:-}" base t rc head prev_conflict=false
  base="repos/$(repo_of "$key")"
  t="$(mktemp -d)"

  gh_get "$base/pulls/$pr" >"$t/pr" || { rc=$?; rm -rf "$t"; return "$rc"; }
  head="$(jq -r '.head.sha' "$t/pr")"
  gh_collect "$base/commits/$head/check-runs" .check_runs "$t/checks" || { rc=$?; rm -rf "$t"; return "$rc"; }
  gh_collect "$base/commits/$head/statuses" . "$t/statuses" || { rc=$?; rm -rf "$t"; return "$rc"; }
  gh_collect "$base/pulls/$pr/reviews" . "$t/reviews" || { rc=$?; rm -rf "$t"; return "$rc"; }
  gh_collect "$base/pulls/$pr/comments" . "$t/review_comments" || { rc=$?; rm -rf "$t"; return "$rc"; }
  gh_collect "$base/issues/$pr/comments" . "$t/issue_comments" || { rc=$?; rm -rf "$t"; return "$rc"; }

  # GitHub computes mergeability lazily: null means "not yet", so the last
  # known answer is kept rather than reporting a conflict that may be gone.
  if [ -n "$prev" ] && [ -f "$prev" ]; then prev_conflict="$(jq '.conflict // false' "$prev")"; fi

  jq -n "$GITHUB_STATE_DEFS"'
    ($p[0]) as $pr_
    | {
      repo: $repo, pr: $num,
      state: (if $pr_.merged then "MERGED" elif $pr_.state == "closed" then "DECLINED" else "OPEN" end),
      head: $pr_.head.sha, dest_head: $pr_.base.sha,
      dest_branch: ($pr_.base.ref // null),
      merge_commit: (if $pr_.merged then ($pr_.merge_commit_sha // null) else null end),
      title: $pr_.title, url: $pr_.html_url,
      participants: ($r | map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
        | group_by(.user.login) | map(last)
        | map({key: (.user.login // "ghost"), value: {name: (.user.login // "ghost"),
            state: (if .state == "APPROVED" then "approved" elif .state == "CHANGES_REQUESTED" then "changes_requested" else null end)}})
        | map(select(.value.state != null)) | from_entries),
      statuses: (ci_entries($c; $s) | from_entries),
      comments: ([($rvc + $isc)[] | {key: (.id | tostring), value: {author: (.user.login // "ghost"),
          path: (.path // null), line: (.line // .original_line // null), deleted: false}}] | from_entries),
      conflict: (if $pr_.mergeable == null then $prev
                 else ($pr_.mergeable == false or $pr_.mergeable_state == "dirty") end),
      fetched_at: $now }' \
    --arg repo "$key" --argjson num "$pr" --argjson prev "$prev_conflict" --arg now "$(prw_iso)" \
    --slurpfile p "$t/pr" --slurpfile c "$t/checks" --slurpfile s "$t/statuses" \
    --slurpfile r "$t/reviews" --slurpfile rvc "$t/review_comments" --slurpfile isc "$t/issue_comments"
  rc=$?
  rm -rf "$t"
  return "$rc"
}

# github_build_fetch KEY COMMIT [PR_SNAPSHOT_FILE] — the build snapshot of one
# commit. A fast-forward merge keeps the PR head as the merge commit: a status
# the PR phase already saw there, same key and same updated, is the finished
# PR run and must not pass for the branch run, so it is dropped.
github_build_fetch() {
  local key="$1" commit="$2" prsnap="${3:-}" t rc base
  t="$(mktemp -d)"
  base="repos/$(repo_of "$key")"
  gh_collect "$base/commits/$commit/check-runs" .check_runs "$t/checks" || { rc=$?; rm -rf "$t"; return "$rc"; }
  gh_collect "$base/commits/$commit/statuses" . "$t/statuses" || { rc=$?; rm -rf "$t"; return "$rc"; }
  if [ -n "$prsnap" ] && [ -f "$prsnap" ]; then cp "$prsnap" "$t/p"; else printf '{}' >"$t/p"; fi

  jq -n "$GITHUB_STATE_DEFS"'
    ($p[0]) as $p | ($p.head // "") as $h
    | ($h != "" and (($h | startswith($commit)) or ($commit | startswith($h)))) as $same
    | {repo: $repo, commit: $commit, phase: "build",
       statuses: (ci_entries($c; $s)
         | map(select(($same and .value.updated != null and ($p.statuses[.key].updated // null) == .value.updated) | not))
         | from_entries),
       fetched_at: $now}' \
    --arg repo "$key" --arg commit "$commit" --arg now "$(prw_iso)" \
    --slurpfile c "$t/checks" --slurpfile s "$t/statuses" --slurpfile p "$t/p"
  rc=$?
  rm -rf "$t"
  return "$rc"
}
