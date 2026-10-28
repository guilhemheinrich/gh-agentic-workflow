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
#   - the per-spec event log specs/NNN-slug/linear.json.
# It never judges a document. When a fact has no matching event in the log,
# it asks the agent ONCE to render a template and make the Linear MCP call,
# then to append the event with linear-record.sh.
#
# Advisory only. It never denies a tool, never guards a file, never asks
# twice for the same fact key, and stays silent when:
#   - the turn ended on a question (the key is not consumed: asked later),
#   - a Stop hook already continued this stop (stop_hook_active=true),
#   - the repository has no .linear.json (absence means "do not publish"),
#   - the spec's log holds an `unavailable` event (no Linear connector),
#   - anything it needs is missing (jq, git, a spec folder).
# The only output is {"decision":"block","reason":…}: on a Stop hook that
# means "take one more turn", not "refuse".
#
# Env knobs (all optional):
#   LINEAR_LIFECYCLE=0                 disable unconditionally
#   LINEAR_LIFECYCLE_DIR=PATH          templates + phases.json (default ../linear)
#   LINEAR_LIFECYCLE_STATE=PATH        asked-keys store (default <git-common-dir>/linear-lifecycle)
#   LINEAR_CONFIG=PATH                 repo config (default <root>/.linear.json)
#   LINEAR_LIFECYCLE_GH=0              disable PR lookups
#   LINEAR_LIFECYCLE_GH_TIMEOUT=3      seconds before a gh call is abandoned
#   LINEAR_LIFECYCLE_GH_TTL=60         seconds a gh answer is reused

set -uo pipefail

[[ "${LINEAR_LIFECYCLE:-1}" == "1" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="${LINEAR_LIFECYCLE_DIR:-$HERE/../linear}"
PHASES="$TPL_DIR/phases.json"
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
config="${LINEAR_CONFIG:-$root/.linear.json}"
[[ -f "$config" ]] || exit 0
[[ -f "$PHASES" ]] || exit 0
[[ -d "$root/specs" ]] || exit 0

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
  out="$(cd "$root" && run_bounded "$GH_TIMEOUT" gh pr view "$branch" --json number,state,url)" || out=""
  out="$(printf '%s' "$out" | jq -c '{number, state, url}' 2>/dev/null)" || out=""
  mkdir -p "$STATE_DIR" 2>/dev/null || { printf '%s' "$out"; return 0; }
  local cur='{}' tmp="$cache.$$"
  [[ -s "$cache" ]] && jq -e . "$cache" >/dev/null 2>&1 && cur="$(cat "$cache")"
  printf '%s' "$cur" | jq --arg b "$branch" --argjson now "$now" --arg pr "$out" \
    '.[$b] = {at: $now, pr: ($pr | if . == "" then null else fromjson end)}' >"$tmp" 2>/dev/null && mv "$tmp" "$cache"
  rm -f "$tmp" 2>/dev/null
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
(( ${#candidates[@]} > 0 )) || exit 0

repo_name="$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[/:]##')"
[[ -n "$repo_name" ]] || repo_name="$(basename "$root")"
team="$(jq -r '.team // ""' "$config" 2>/dev/null)"
project="$(jq -r '.project // ""' "$config" 2>/dev/null)"

emit() { # KEY REASON — mark the key, then ask the agent once
  asked_add "$1"
  jq -n --arg r "$2" '{decision: "block", reason: $r}'
  exit 0
}

# ── One fact per turn, earliest in the lifecycle first ──────────────────────
for slug in "${candidates[@]}"; do
  dir="$root/specs/$slug"
  rel="specs/$slug"
  log="$dir/linear.json"
  events='[]'
  [[ -s "$log" ]] && events="$(jq -c '.events // []' "$log" 2>/dev/null || echo '[]')"
  has() { printf '%s' "$events" | jq -e --arg e "$1" 'any(.[]; .event == $e)' >/dev/null 2>&1; }
  has unavailable && continue
  issue="$(printf '%s' "$events" | jq -r '[.[] | select(.event == "created" or .event == "linked") | .id] | last // ""')"
  record="\"\$CLAUDE_PROJECT_DIR/.agents/hooks/linear-record.sh\" $rel"
  noregress="If it is already at that state or later (In Review, Done, Canceled), do not move it: skip step 1 and still run step 3. A lifecycle move never goes backwards."
  footer="If no Linear MCP tool is available in this session, run instead: $record unavailable — and stop. Do not mention this hook to the user unless the Linear call needs their decision."

  # specify — spec.md exists, no issue known yet
  if [[ -z "$issue" ]] && phase_enabled specify && [[ -f "$dir/spec.md" ]]; then
    key="specify:$slug"
    asked_has "$key" && continue
    tpl="$(phase_template specify)"
    title="$(spec_title "$dir/spec.md")"; [[ -n "$title" ]] || title="$slug"
    max="$(jq -r '.duplicateSearch.maxCandidates // 20' "$PHASES")"
    emit "$key" "[linear-lifecycle] Fact: $rel/spec.md exists and no Linear issue is recorded for it.
1. Search Linear for an existing issue with this title (list_issues, query \"$title\", team \"$team\", at most $max candidates). If one may be the same work, show it to the user and ask; if they confirm, run: $record linked <ID> <URL>.
2. Otherwise render .agents/linear/$tpl with: title=\"$title\", repo=$repo_name, spec_path=$rel/spec.md, branch=${branch:-?}, commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null). Create the issue with save_issue in team \"$team\", project \"$project\", using the rendered body as description.
3. Then run: $record created <ID> <URL>
$footer"
  fi
  [[ -n "$issue" ]] || continue

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
2. Render .agents/linear/$tpl with: issue=$issue, ticked=$ticked, total=$total, branch=${branch:-?}, and post it with save_comment on $issue.
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
2. Render .agents/linear/$tpl with: issue=$issue, pr_number=$num, pr_url=$url, branch=$branch, and post it with save_comment on $issue. Attach the PR link to the issue if the tool allows it.
3. Then run: $record in_review $issue $url
$footer"
      fi
    fi
  fi
done

exit 0
