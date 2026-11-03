#!/usr/bin/env bash
# diff.sh — turn two snapshots of one PR into transition lines, and decide
# which of them deserve to wake the session that subscribed.

# diff_snapshots OLD_FILE NEW_FILE SUBSCRIPTION_JSON — JSONL on stdout:
#   {"kind","wake","urgent","text"}
# A missing OLD_FILE is a baseline: nothing is printed.
#
# Own actions never wake: a head the session pushed (own_heads, compared by
# prefix because Bitbucket returns 12-char hashes and git 40-char ones) and a
# comment the session posted (ignored_comments). Author filtering cannot work:
# the agent and the human share one Bitbucket account.
diff_snapshots() {
  local old="$1" new="$2" sub="$3"
  [ -f "$old" ] || return 0
  jq -cn --slurpfile o "$old" --slurpfile n "$new" --argjson sub "$sub" '
    def terminal: . == "SUCCESSFUL" or . == "FAILED" or . == "STOPPED";
    def own($h): any($sub.own_heads[]?; . as $x | ($x | startswith($h)) or ($h | startswith($x)));
    $o[0] as $o | $n[0] as $n
    | (($n.repo | split("/") | last) + "#" + ($n.pr | tostring)) as $id
    | [
        # PR state
        (select($o.state != $n.state and ($n.state | IN("MERGED", "DECLINED", "SUPERSEDED")))
         | {kind: "state", wake: true, urgent: false, text: "\($id) \($n.state | ascii_downcase)"}),
        # head pushed outside this session
        (select($o.head != $n.head and (own($n.head) | not))
         | {kind: "head", wake: true, urgent: false,
            text: "\($id) new commit \($n.head[0:7]) pushed outside this session"}),
        # commit statuses (pipelines and external builds). Statuses belong to
        # a commit: on a new head every status is new, so a build that fails
        # again on the fix commit still wakes.
        ($n.statuses | to_entries[] | .key as $k | .value as $s
         | (if $o.head == $n.head then ($o.statuses[$k].state // "new") else "new" end) as $was
         | select($was != $s.state)
         | {kind: "status", wake: ($s.state | terminal), urgent: ($s.state == "FAILED"),
            text: "\($id) pipeline \"\($s.name)\" \($was)→\($s.state) · \($n.url)"}),
        # merge conflict
        (select($o.conflict != $n.conflict)
         | {kind: "conflict", wake: true, urgent: false,
            text: "\($id) merge conflict \(if $n.conflict then "appeared" else "cleared" end)"}),
        # reviews: approvals and change requests, added or withdrawn
        (($o.participants + $n.participants) | keys[] as $k
         | ($o.participants[$k].state // null) as $was
         | ($n.participants[$k].state // null) as $is
         | select($was != $is)
         | (($n.participants[$k] // $o.participants[$k]).name) as $who
         | {kind: "review", wake: true, urgent: false,
            text: "\($id) \($who) \(
              if $is == "approved" then "approved"
              elif $is == "changes_requested" then "requested changes"
              elif $was == "approved" then "withdrew approval"
              else "withdrew the change request" end)"}),
        # new comments, not posted by this session, not deleted
        ($n.comments | to_entries[]
         | select($o.comments[.key] == null and (.value.deleted | not)
                  and ((.key as $c | $sub.ignored_comments | index($c)) == null))
         | {kind: "comment", wake: true, urgent: false,
            text: "\($id) comment by \(.value.author)\(
              if .value.path then " on \(.value.path):\(.value.line)" else "" end) (id \(.key))"})
      ] | .[]'
}

# build_transitions OLD_FILE NEW_FILE — one log text per status that moved on
# a followed commit. Never a wake: the build phase wakes once, at its end.
build_transitions() {
  [ -f "$1" ] || return 0
  jq -rn --slurpfile o "$1" --slurpfile n "$2" '
    $o[0] as $o | $n[0] as $n
    | $n.statuses | to_entries[] | ($o.statuses[.key].state // "new") as $was
    | select($was != .value.state)
    | "\($n.repo)@\($n.commit[0:7]) pipeline \"\(.value.name)\" \($was)→\(.value.state)"'
}

# build_verdict SNAPSHOT_FILE SUBSCRIPTION_JSON NOW — one {"urgent","text"}
# line once the build phase of SUBSCRIPTION is over, nothing while it runs.
# Over means: every status on the commit is terminal (one wake, urgent when
# one FAILED), or no status appeared within PRW_BUILD_FIRST_SECONDS (a branch
# without pipeline), or the phase outlived PRW_BUILD_MAX_SECONDS.
build_verdict() {
  jq -c --argjson sub "$2" --argjson now "$3" \
    --argjson first "${PRW_BUILD_FIRST_SECONDS:-900}" --argjson max "${PRW_BUILD_MAX_SECONDS:-21600}" '
    def terminal: . == "SUCCESSFUL" or . == "FAILED" or . == "STOPPED";
    ($sub.repo | split("/") | last) as $r
    | (if $sub.pr then "\($r)#\($sub.pr)" else $r end) as $id
    | (if $sub.origin == "merge" then "after merge into \($sub.build_branch // "?")"
       else "push to \($sub.build_branch // "?")" end) as $what
    | "\($id) \($what) @\(($sub.commit // "unknown")[0:7])" as $head
    | [.statuses[]?] as $st
    | ($now - ($sub.build_since // $now)) as $age
    | ([$st[] | "\"\(.name)\" \(.state)"] | join(", ")) as $list
    | (([$st[] | select(.state == "FAILED") | .url] + [$st[] | .url]) | map(select(. != null)) | first) as $url
    | if ($st | length) > 0 and all($st[]; .state | terminal) then
        {urgent: any($st[]; .state == "FAILED"), text: "\($head): \($list)\(if $url then " · \($url)" else "" end)"}
      elif ($st | length) == 0 and $age >= $first then
        {urgent: false, text: "\($head): no pipeline reported within \($first / 60 | floor) min — watch closed"}
      elif $age >= $max then
        {urgent: false, text: "\($head): still running after \($max / 3600 | floor) h (\($list)) — watch closed"}
      else empty end' "$1"
}
