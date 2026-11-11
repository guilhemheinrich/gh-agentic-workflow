#!/usr/bin/env bash
# linear-lifecycle.sh — Claude Code Stop hook: follow a spec-kit change in Linear.
#
# Installed once into a consumer repository by the linear-tracker skill
# (scripts/install-lifecycle.sh). After that it depends on nothing but
# bash, jq, git and, optionally, gh.
#
# At the end of a turn it gathers FACTS only:
#   - which specs/NNN-slug/ is current (git branch, else uncommitted files),
#   - whether spec.md exists, how many tasks of tasks.md are ticked,
#   - the PR state of the branch (gh, bounded and cached),
#   - the per-spec event log specs/NNN-slug/linear.json (events + the spec's
#     Linear `project`).
# It never judges a document. When a fact has no matching event in the log,
# it asks the agent ONCE to render a template and make the Linear MCP call,
# then to append the event with linear-record.sh.
#
# Advisory only. It never denies a tool, never guards a file, never asks
# twice for the same fact key, and stays silent when:
#   - the turn ended on a question (the key is not consumed: asked later),
#   - a Stop hook already continued this stop (stop_hook_active=true),
#   - phases.json is absent or names no `team` (that file is the switch: no
#     team, no Linear in this repository),
#   - this machine recorded `unavailable` for the spec less than a TTL ago
#     (no Linear connector; kept in the local state dir, never committed),
#   - anything it needs is missing (jq, git, a spec folder).
# The only output is {"decision":"block","reason":…}: on a Stop hook that
# means "take one more turn", not "refuse".
#
# Env knobs (all optional):
#   LINEAR_LIFECYCLE=0                 disable unconditionally
#   LINEAR_LIFECYCLE_DIR=PATH          templates + phases.json (default ../linear, i.e. .claude/linear)
#   LINEAR_LIFECYCLE_STATE=PATH        asked-keys store (default <git-common-dir>/linear-lifecycle)
#   LINEAR_CONFIG=PATH                 phases.json to use (default: LINEAR_LIFECYCLE_DIR/phases.json)
#   LINEAR_LIFECYCLE_UNAVAILABLE_TTL=14400  seconds an `unavailable` mark silences a spec
#   LINEAR_LIFECYCLE_GH=0              disable PR lookups
#   LINEAR_LIFECYCLE_GH_TIMEOUT=3      seconds before a gh call is abandoned
#   LINEAR_LIFECYCLE_GH_TTL=60         seconds a gh answer is reused
#
# The `deployed` phase (off unless phases.json enables it) turns "merged" into
# "deployed": for a PR MERGED into one of `phases.deployed.targets`, it reads the
# workflow runs of the merge commit (gh run list --commit). Any run still going:
# silence, nothing consumed (the next stop, or the next pr-watch wake-up, comes
# back). All runs green: ask once to move the issue to Done. A run failed or
# cancelled: ask once to name it and leave the issue open. No run at all after
# `noPipelineDelay` seconds: ask once, the agent judges. The issue is the spec's,
# else `<teamKey>-<n>` read from the branch name or the PR title (`teamKey` in
# phases.json), so the phase needs no specs/ folder.

set -uo pipefail

[[ "${LINEAR_LIFECYCLE:-1}" == "1" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="${LINEAR_LIFECYCLE_DIR:-$HERE/../linear}"
PHASES="${LINEAR_CONFIG:-$TPL_DIR/phases.json}"
UNAVAILABLE_TTL="${LINEAR_LIFECYCLE_UNAVAILABLE_TTL:-14400}"
RECORD="$HERE/linear-record.sh"
GH_ENABLED="${LINEAR_LIFECYCLE_GH:-1}"
GH_TIMEOUT="${LINEAR_LIFECYCLE_GH_TIMEOUT:-3}"
GH_TTL="${LINEAR_LIFECYCLE_GH_TTL:-60}"

payload="$(cat 2>/dev/null || true)"
field() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

[[ "$(field '.stop_hook_active')" == "true" ]] && exit 0
cwd="$(field '.cwd')"; [[ -n "$cwd" && -d "$cwd" ]] || cwd="$(pwd)"
transcript="$(field '.transcript_path')"

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -f "$PHASES" ]] || exit 0
# The switch: phases.json names the Linear team. Absent or empty -> silent.
team="$(jq -r '.team // ""' "$PHASES" 2>/dev/null)"
[[ -n "$team" ]] || exit 0
# No specs/ test here: the `deployed` phase also serves repositories without spec-kit.

# ── The turn ended on a question: stay silent, consume nothing ──────────────
last="$(field '.last_assistant_message')"
if [[ -z "$last" && -n "$transcript" && -f "$transcript" ]]; then
  last="$(grep -E '"type":"assistant"' "$transcript" 2>/dev/null | tail -n 40 \
    | jq -rs '[.[] | .message.content[]? | select(.type == "text") | .text] | last // ""' 2>/dev/null)"
fi
if printf '%s' "$last" | sed -e 's/[[:space:]*_`)]*$//' | tail -c 2 | grep -q '?'; then
  exit 0
fi

# ── Asked-keys store, outside the work tree, shared by every worktree ───────
common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || exit 0
[[ "$common" = /* ]] || common="$root/$common"
STATE_DIR="${LINEAR_LIFECYCLE_STATE:-$common/linear-lifecycle}"
ASKED="$STATE_DIR/asked.json"

asked_has() {
  [[ -s "$ASKED" ]] || return 1
  jq -e --arg k "$1" '.keys[$k] != null' "$ASKED" >/dev/null 2>&1
}

# `unavailable` is a machine-local fact: no Linear connector in a session here.
# Kept next to asked.json (never in the committed log), keyed by spec, and it
# expires after UNAVAILABLE_TTL so a later session that has the connector asks again.
UNAVAILABLE="$STATE_DIR/unavailable.json"
unavailable_active() {
  [[ -s "$UNAVAILABLE" ]] || return 1
  jq -e --arg s "$1" --argjson now "$(date +%s)" --argjson ttl "$UNAVAILABLE_TTL" \
    '.[$s] != null and ($now - .[$s]) < $ttl' "$UNAVAILABLE" >/dev/null 2>&1
}

asked_add() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  local cur tmp="$ASKED.$$"
  cur='{"keys":{}}'
  [[ -s "$ASKED" ]] && jq -e . "$ASKED" >/dev/null 2>&1 && cur="$(cat "$ASKED")"
  printf '%s' "$cur" | jq --arg k "$1" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.keys[$k] = $at' >"$tmp" 2>/dev/null && mv "$tmp" "$ASKED"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ── Helpers ──────────────────────────────────────────────────────────────────
run_bounded() { # SECS CMD... — stdout of CMD; fails on timeout or error
  local secs="$1"; shift
  local out; out="$(mktemp)" || return 1
  "$@" >"$out" 2>/dev/null &
  local pid=$! ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( ticks >= secs * 10 )); then kill "$pid" 2>/dev/null; rm -f "$out"; return 1; fi
    sleep 0.1; ticks=$((ticks + 1))
  done
  wait "$pid"; local rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

phase_enabled() { jq -e --arg p "$1" '.phases[$p].enabled == true' "$PHASES" >/dev/null 2>&1; }
phase_template() { jq -r --arg p "$1" '.phases[$p].template // empty' "$PHASES" 2>/dev/null; }
state_names() { jq -r --arg s "$1" '(.states[$s] // []) | map("«" + . + "»") | join(" / ")' "$PHASES" 2>/dev/null; }

count_ticked() { grep -cE '^[[:space:]]*[-*] \[[xX]\]' "$1" 2>/dev/null || true; }
count_tasks() { grep -cE '^[[:space:]]*[-*] \[[ xX]\]' "$1" 2>/dev/null || true; }

spec_title() { # first H1 of spec.md, without spec-kit's "Feature Specification:" prefix
  grep -m1 -E '^# ' "$1" 2>/dev/null | sed -E 's/^# +//; s/^Feature Specification: *//'
}

# pr_lookup BRANCH -> JSON {number,state,url} or empty
pr_lookup() {
  local branch="$1" now cache cached out
  [[ "$GH_ENABLED" == "1" ]] && command -v gh >/dev/null 2>&1 || return 0
  now="$(date +%s)"
  cache="$STATE_DIR/pr-cache.json"
  if [[ -s "$cache" ]]; then
    cached="$(jq -c --arg b "$branch" --argjson now "$now" --argjson ttl "$GH_TTL" \
      '.[$b] | select(. != null and ($now - .at) < $ttl) | .pr' "$cache" 2>/dev/null)"
    if [[ -n "$cached" ]]; then [[ "$cached" != "null" ]] && printf '%s' "$cached"; return 0; fi
  fi
  out="$(cd "$root" && run_bounded "$GH_TIMEOUT" gh pr view "$branch" --json number,state,url,title,baseRefName,mergeCommit,mergedAt)" || out=""
  out="$(printf '%s' "$out" | jq -c '{number, state, url, title, base: .baseRefName, commit: (.mergeCommit.oid // null), mergedAt}' 2>/dev/null)" || out=""
  mkdir -p "$STATE_DIR" 2>/dev/null || { printf '%s' "$out"; return 0; }
  local cur='{}' tmp="$cache.$$"
  [[ -s "$cache" ]] && jq -e . "$cache" >/dev/null 2>&1 && cur="$(cat "$cache")"
  printf '%s' "$cur" | jq --arg b "$branch" --argjson now "$now" --arg pr "$out" \
    '.[$b] = {at: $now, pr: ($pr | if . == "" then null else fromjson end)}' >"$tmp" 2>/dev/null && mv "$tmp" "$cache"
  rm -f "$tmp" 2>/dev/null
  printf '%s' "$out"
}

# runs_lookup SHA -> JSON array of runs of that commit, or empty when gh failed.
# Only a settled answer (non-empty, every run completed) is cached: a pending
# list must be read fresh at the next wake-up.
runs_lookup() {
  local sha="$1" cache="$STATE_DIR/runs-cache.json" out
  [[ "$GH_ENABLED" == "1" ]] && command -v gh >/dev/null 2>&1 || return 0
  if [[ -s "$cache" ]]; then
    out="$(jq -c --arg s "$sha" '.[$s] // empty' "$cache" 2>/dev/null)"
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  fi
  out="$(cd "$root" && run_bounded "$GH_TIMEOUT" gh run list --commit "$sha" --limit 50 \
    --json databaseId,status,conclusion,workflowName,url)" || return 0
  out="$(printf '%s' "$out" | jq -c 'if type == "array" then . else empty end' 2>/dev/null)" || return 0
  [[ -n "$out" ]] || return 0
  if [[ "$(printf '%s' "$out" | jq 'length > 0 and all(.[]; .status == "completed")')" == "true" ]] \
    && mkdir -p "$STATE_DIR" 2>/dev/null; then
    local cur='{}' tmp="$cache.$$"
    [[ -s "$cache" ]] && jq -e . "$cache" >/dev/null 2>&1 && cur="$(cat "$cache")"
    printf '%s' "$cur" | jq --arg s "$sha" --argjson r "$out" '.[$s] = $r' >"$tmp" 2>/dev/null && mv "$tmp" "$cache"
    rm -f "$tmp" 2>/dev/null
  fi
  printf '%s' "$out"
}

# ── Which specs are current: facts from git only ────────────────────────────
branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
candidates=()
if [[ -n "$branch" && -d "$root/specs/$branch" ]]; then
  candidates+=("$branch")
elif [[ "$branch" =~ ^([0-9]{3})- ]]; then
  for d in "$root/specs/${BASH_REMATCH[1]}"-*/; do
    [[ -d "$d" ]] && candidates+=("$(basename "$d")")
  done
fi
if (( ${#candidates[@]} == 0 )); then
  while IFS= read -r slug; do
    [[ -n "$slug" && -d "$root/specs/$slug" ]] && candidates+=("$slug")
  done < <(git -C "$root" status --porcelain --untracked-files=all -- specs 2>/dev/null \
    | sed -E 's/^.{3}//; s/.* -> //' | sed -nE 's#^specs/([0-9]{3}-[^/]+)/.*#\1#p' | sort -u)
fi

repo_name="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[/:]##')"
[[ -n "$repo_name" ]] || repo_name="$(basename "$root")"

emit() { # KEY REASON — mark the key, then ask the agent once
  asked_add "$1"
  jq -n --arg r "$2" '{decision: "block", reason: $r}'
  exit 0
}

DEPLOYED_STORE="$STATE_DIR/deployed.json" # issues already Done: machine-local memory for tickets without a spec
deployed_known() { # ISSUE [EVENTS_JSON]
  [[ -s "$DEPLOYED_STORE" ]] && jq -e --arg i "$1" '.[$i] != null' "$DEPLOYED_STORE" >/dev/null 2>&1 && return 0
  [[ -n "${2:-}" ]] && printf '%s' "$2" | jq -e 'any(.[]; .event == "deployed")' >/dev/null 2>&1 && return 0
  return 1
}

# deployed_check ISSUE SLUG(empty without a spec) EVENTS_JSON — the merged-and-deployed fact.
deployed_check() {
  local issue="$1" slug="$2" events="${3:-}" pr state base sha short num url runs rec footer tpl age delay
  phase_enabled deployed || return 0
  [[ -n "$branch" ]] || return 0
  deployed_known "$issue" "$events" && return 0
  pr="$(pr_lookup "$branch")"; [[ -n "$pr" ]] || return 0
  state="$(printf '%s' "$pr" | jq -r '.state // ""')"; [[ "$state" == "MERGED" ]] || return 0
  base="$(printf '%s' "$pr" | jq -r '.base // ""')"
  jq -e --arg b "$base" '(.phases.deployed.targets // []) | index($b) != null' "$PHASES" >/dev/null 2>&1 || return 0
  sha="$(printf '%s' "$pr" | jq -r '.commit // ""')"; [[ -n "$sha" ]] || return 0
  short="${sha:0:7}"
  num="$(printf '%s' "$pr" | jq -r '.number')"; url="$(printf '%s' "$pr" | jq -r '.url')"
  runs="$(runs_lookup "$sha")"; [[ -n "$runs" ]] || return 0
  tpl="$(phase_template deployed)"
  if [[ -n "$slug" ]]; then
    rec="\"\$CLAUDE_PROJECT_DIR/.claude/hooks/linear-record.sh\" specs/$slug"
    footer="If no Linear MCP tool is available in this session, run instead: $rec unavailable — and stop. Do not mention this hook to the user unless the Linear call needs their decision."
  else
    rec="\"\$CLAUDE_PROJECT_DIR/.claude/hooks/linear-record.sh\" -"
    footer="If no Linear MCP tool is available in this session, stop. Do not mention this hook to the user unless the Linear call needs their decision."
  fi
  local list; list="$(printf '%s' "$runs" | jq -r 'map("\(.workflowName) → \(.conclusion // .status) (\(.url))") | join("; ")')"

  if [[ "$(printf '%s' "$runs" | jq 'any(.[]; .status != "completed")')" == "true" ]]; then
    return 0 # a pipeline is still running: silence, consume nothing
  fi
  if [[ "$(printf '%s' "$runs" | jq 'length')" == "0" ]]; then
    delay="$(jq -r '.phases.deployed.noPipelineDelay // 300' "$PHASES")"
    age="$(printf '%s' "$pr" | jq -r --argjson now "$(date +%s)" '(.mergedAt // "" | try fromdateiso8601 catch null) as $m | if $m == null then 999999999 else $now - $m end')"
    (( age >= delay )) || return 0
    local key="deploy-nopipe:$issue:$short"; asked_has "$key" && return 0
    emit "$key" "[linear-lifecycle] Fact: PR #$num ($url) is merged into $base (commit $short) and no pipeline ran for that commit ${delay}s after the merge. Nothing proves a deployment: $issue is not moved to Done by this hook.
Judge it: if this repository deploys by other means, check that, and only then move $issue to the first existing state among $(state_names done) with save_issue (get_issue first: never move a Done or Canceled issue). Otherwise leave $issue open and say why in a comment.
$footer"
  fi
  local bad; bad="$(printf '%s' "$runs" | jq -r '[.[] | select(.conclusion | IN("success","skipped","neutral") | not)] | map("\(.workflowName) → \(.conclusion) (\(.url))") | join("; ")')"
  if [[ -n "$bad" ]]; then
    local key="deploy-failed:$issue:$short"; asked_has "$key" && return 0
    emit "$key" "[linear-lifecycle] Fact: PR #$num ($url) is merged into $base but a pipeline of commit $short did not succeed: $bad.
Do NOT move $issue to Done: merged is not deployed. Name the failing run and its link to the user, leave $issue open, and fix or report the failure (a re-run that goes green is reported again by pr-watch)."
  fi
  local key="deployed:$issue:$short"; asked_has "$key" && return 0
  emit "$key" "[linear-lifecycle] Fact: PR #$num ($url) is merged into $base and every pipeline of commit $short is green: $list.
0. Read the current state of $issue first (get_issue). If it is already Done or Canceled, do not move it: skip step 1 and run step 3.
1. Move $issue to the first existing state among $(state_names done) (save_issue; list_issue_statuses if the name is unknown; else the team's first state of type completed).
2. Render .claude/linear/$tpl with: issue=$issue, pr_number=$num, pr_url=$url, base=$base, commit=$short, runs=\"$list\", and post it with save_comment on $issue.
3. Then run: $rec deployed $issue $url
$footer"
}

# ── One fact per turn, earliest in the lifecycle first ──────────────────────
had_issue=0
for slug in "${candidates[@]}"; do
  dir="$root/specs/$slug"
  rel="specs/$slug"
  log="$dir/linear.json"
  events='[]'
  [[ -s "$log" ]] && events="$(jq -c '.events // []' "$log" 2>/dev/null || echo '[]')"
  has() { printf '%s' "$events" | jq -e --arg e "$1" 'any(.[]; .event == $e)' >/dev/null 2>&1; }
  unavailable_active "$slug" && continue
  project=""
  [[ -s "$log" ]] && project="$(jq -r '.project // ""' "$log" 2>/dev/null)"
  issue="$(printf '%s' "$events" | jq -r '[.[] | select(.event == "created" or .event == "linked") | .id] | last // ""')"
  record="\"\$CLAUDE_PROJECT_DIR/.claude/hooks/linear-record.sh\" $rel"
  noregress="If it is already at that state or later (In Review, Done, Canceled), do not move it: skip step 1 and still run step 3. A lifecycle move never goes backwards."
  subissues="List the sub-issues of $issue (list_issues, parentId $issue). One that this change resolves gets its own comment and moves to Done; never post its answer on $issue, and name sub-issues by identifier."
  footer="If no Linear MCP tool is available in this session, run instead: $record unavailable — and stop. Do not mention this hook to the user unless the Linear call needs their decision."

  # specify — spec.md exists, no issue known yet
  if [[ -z "$issue" ]] && phase_enabled specify && [[ -f "$dir/spec.md" ]]; then
    tpl="$(phase_template specify)"
    title="$(spec_title "$dir/spec.md")"; [[ -n "$title" ]] || title="$slug"
    max="$(jq -r '.duplicateSearch.maxCandidates // 20' "$PHASES")"
    if [[ -z "$project" ]]; then
      # The project follows the spec, never the repository. None is recorded:
      # do not create anything. The `specify:` key stays unconsumed, so the
      # create reminder comes back once a project is recorded; this
      # distinct key only keeps the "find a project" reminder from repeating.
      key="specify-project:$slug"
      asked_has "$key" && continue
      emit "$key" "[linear-lifecycle] Fact: $rel/spec.md exists, no Linear issue is recorded for it, and no Linear project is recorded for this spec ($rel/linear.json has no \"project\"). Do not create an issue yet, and never with an empty or guessed project.
1. Search Linear for an existing issue with this title (list_issues, query \"$title\", team \"$team\", at most $max candidates). If one may be the same work, show it to the user and ask; if they confirm, run: $record linked <ID> <URL> (a linked issue needs no project).
2. Otherwise find the project, in this order: your session brief or charter; else ask the human which Linear project this spec belongs to. Then run: $record project \"<project name>\"
Once a project is recorded, the next stop will ask you to create the issue.
$footer"
    fi
    key="specify:$slug"
    asked_has "$key" && continue
    emit "$key" "[linear-lifecycle] Fact: $rel/spec.md exists and no Linear issue is recorded for it.
1. Search Linear for an existing issue with this title (list_issues, query \"$title\", team \"$team\", at most $max candidates). If one may be the same work, show it to the user and ask; if they confirm, run: $record linked <ID> <URL>.
2. Otherwise render .claude/linear/$tpl with: title=\"$title\", repo=$repo_name, spec_path=$rel/spec.md, branch=${branch:-?}, commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null). Create the issue with save_issue in team \"$team\", project \"$project\", using the rendered body as description.
3. Then run: $record created <ID> <URL>
$footer"
  fi
  [[ -n "$issue" ]] || continue
  had_issue=1

  # implement — at least one task ticked, issue not yet In Progress
  if phase_enabled implement && ! has in_progress && [[ -f "$dir/tasks.md" ]]; then
    ticked="$(count_ticked "$dir/tasks.md")"; total="$(count_tasks "$dir/tasks.md")"
    if (( ${ticked:-0} > 0 )); then
      key="implement:$slug"
      if ! asked_has "$key"; then
        tpl="$(phase_template implement)"
        emit "$key" "[linear-lifecycle] Fact: $ticked/$total tasks are ticked in $rel/tasks.md and $issue is not recorded as In Progress.
0. Read the current state of $issue first (get_issue). $noregress
1. Move $issue to the first existing state among $(state_names in_progress) (save_issue; list_issue_statuses if the name is unknown; else the team's first state of type started).
2. Render .claude/linear/$tpl with: issue=$issue, ticked=$ticked, total=$total, branch=${branch:-?}, and post it with save_comment on $issue.
Also: $subissues
3. Then run: $record in_progress $issue
$footer"
      fi
    fi
  fi

  # pr-open — the branch has an open PR, issue not yet In Review
  if phase_enabled pr-open && ! has in_review && [[ -n "$branch" ]]; then
    pr="$(pr_lookup "$branch")"
    if [[ -n "$pr" && "$(printf '%s' "$pr" | jq -r '.state')" == "OPEN" ]]; then
      num="$(printf '%s' "$pr" | jq -r '.number')"; url="$(printf '%s' "$pr" | jq -r '.url')"
      key="pr-open:$slug:$num"
      if ! asked_has "$key"; then
        tpl="$(phase_template pr-open)"
        emit "$key" "[linear-lifecycle] Fact: PR #$num is open on branch $branch ($url) and $issue is not recorded as In Review.
0. Read the current state of $issue first (get_issue). $noregress
1. Move $issue to the first existing state among $(state_names in_review) (save_issue; list_issue_statuses if the name is unknown; else the team's first state of type started that follows In Progress).
2. Render .claude/linear/$tpl with: issue=$issue, pr_number=$num, pr_url=$url, branch=$branch, and post it with save_comment on $issue. Attach the PR link to the issue if the tool allows it.
Also: $subissues
3. Then run: $record in_review $issue $url
$footer"
      fi
    fi
  fi

  # deployed — the PR is merged into a target branch and its pipelines settled
  deployed_check "$issue" "$slug" "$events"
done

# deployed without a spec: the issue comes from the branch name or the PR title.
if (( had_issue == 0 )) && phase_enabled deployed && [[ -n "$branch" ]]; then
  tkey="$(jq -r '.teamKey // ""' "$PHASES" 2>/dev/null)"
  if [[ "$tkey" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
    lkey="$(printf '%s' "$tkey" | tr '[:upper:]' '[:lower:]')"
    found=""
    lb="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lb" =~ (^|[^a-z0-9])$lkey-([0-9]+)([^0-9]|$) ]]; then found="${tkey^^}-${BASH_REMATCH[2]}"; fi
    if [[ -z "$found" ]]; then
      lt="$(pr_lookup "$branch" | jq -r '.title // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
      if [[ "$lt" =~ (^|[^a-z0-9])$lkey-([0-9]+)([^0-9]|$) ]]; then found="${tkey^^}-${BASH_REMATCH[2]}"; fi
    fi
    [[ -n "$found" ]] && deployed_check "$found" "" ""
  fi
fi

exit 0
