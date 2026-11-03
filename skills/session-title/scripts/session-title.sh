#!/usr/bin/env bash
# session-title.sh — facts and templated titles for a Claude desktop session.
#
# The title is read while the agent is idle, so it names the HUMAN's next
# action ("🔀 À merger #12 · 042-webhook"), from a fixed template set
# (../templates/titles.json). This script gathers deterministic facts and
# renders titles; the agent judges the status, and only the agent can rename
# (the desktop app's set_session_title tool).
#
# Usage:
#   session-title.sh facts  --session ID [--repo DIR] [--transcript FILE] [--last-message-file FILE]
#   session-title.sh check  --session ID [...same]   # facts + changed=true once per new fingerprint
#   session-title.sh set STATUS --session ID [--repo DIR] [--subject TEXT]
#                                                    # prints the title, or UNCHANGED
#   session-title.sh gate   --session ID            # before AskUserQuestion: deny once, then allow
#   session-title.sh render STATUS [--subject TEXT] [--pr N] [--progress D/T]
#   session-title.sh list [--mode spec|free]
#   session-title.sh forget --session ID
#   session-title.sh sweep  --sessions FILE         # list_sessions JSON -> {sessionId,title} lines to rename
#   session-title.sh snapshot [--days N]            # list_sessions-shaped JSON read from the app's own files
#   session-title.sh watch [--interval S] [--once] [--session LOCAL_ID]
#                                                   # agent-free trigger: one line per new rename the sweep wants;
#                                                   # --session excludes the watcher's own session
#   session-title.sh watcher-status                 # {state: alive|down|never|off, ageSeconds, local}
#   session-title.sh cron                           # cron expression of the freshness sweep
#   session-title.sh config                         # effective user config
#   session-title.sh progress --session ID [--repo DIR]  # live "🔨 D/T" title, or nothing
#   session-title.sh scheduled --transcript FILE    # exit 0 when the session is a scheduled run
#   session-title.sh working --session ID           # prompt arrived: activity menu for the working title
#   session-title.sh restore --session ID           # Stop, facts unchanged: previous title, fresh dot
#
# Freshness: every title carries an age dot ("🟡 🔀 À merger #12 · 042-webhook").
# `set` always renders 🟢 (the turn just ended); a scheduled task runs `sweep`
# to repaint idle sessions. Levels live in ../templates/titles.json; the sweep
# frequency lives in ONE user-level file, $SESSION_TITLE_CONFIG
# (default ~/.config/session-title/config.json):
#   { "freshness": { "enabled": true, "sweepMinutes": 5 }, "progress": { "every": "phase" } }
# progress.every: "phase" (rename when a tasks.md section is all checked) or "task".
#
# Session mode:
#   spec — the session works on a spec-kit feature: the branch names an
#          existing specs/NNN-slug/, the transcript shows a Write/Edit under
#          specs/NNN-slug/ or a /speckit.* command. Sticky once detected.
#   free — everything else ("vibe coding", questions, investigations).
#
# Env knobs (all optional):
#   SESSION_TITLE_LANG=en|fr       language of every status and activity label (default en)
#   SESSION_TITLE_TEMPLATES=PATH   template file override
#   SESSION_TITLE_CACHE=DIR        per-session cache (default ~/.cache/session-title)
#   SESSION_TITLE_GH=0             disable gh lookups
#   SESSION_TITLE_GH_TIMEOUT=4     seconds before a gh call is abandoned
#   SESSION_TITLE_GH_TTL=60        seconds a gh answer is reused
#   SESSION_TITLE_GATE_TTL=300     seconds the question gate stays open after a deny
#   SESSION_TITLE_APP_DIR=DIR      desktop app session files (default ~/Library/Application Support/Claude/claude-code-sessions)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SESSION_TITLE_TEMPLATES:-$SCRIPT_DIR/../templates/titles.json}"
LANG_KEY="${SESSION_TITLE_LANG:-en}"
CACHE_DIR="${SESSION_TITLE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/session-title}"
GH_ENABLED="${SESSION_TITLE_GH:-1}"
GH_TIMEOUT="${SESSION_TITLE_GH_TIMEOUT:-4}"
GH_TTL="${SESSION_TITLE_GH_TTL:-60}"
CONFIG_FILE="${SESSION_TITLE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/session-title/config.json}"
# Desktop app session files: macOS, then Windows (Git Bash exports APPDATA as a
# Windows path, so it is converted when cygpath exists).
if [[ -n "${SESSION_TITLE_APP_DIR:-}" ]]; then APP_DIR="$SESSION_TITLE_APP_DIR"
elif [[ -n "${APPDATA:-}" ]]; then
  APP_DIR="$(cygpath -u "$APPDATA" 2>/dev/null || printf '%s' "$APPDATA")/Claude/claude-code-sessions"
else APP_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"; fi
WATCHER_FILE="$CACHE_DIR/watcher.json"
HEARTBEAT_FILE="$CACHE_DIR/watch-heartbeat.json"

die() { printf 'session-title: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -f "$TEMPLATES" ]] || die "templates not found: $TEMPLATES"

# ── User config ──────────────────────────────────────────────────────────────
# Defaults deep-merged with the user file; a missing or broken file means defaults.
config() {
  local user='{}'
  [[ -s "$CONFIG_FILE" ]] && user="$(jq -c . "$CONFIG_FILE" 2>/dev/null)" || true
  [[ -n "$user" ]] || user='{}'
  jq -n --argjson u "$user" '{freshness: {enabled: true, sweepMinutes: 5}, progress: {every: "phase"}} * $u'
}

# is_scheduled TRANSCRIPT — the session is a scheduled-task run, or the
# freshness watcher: nobody reads its title, so the hooks stay silent there.
# The watcher is recognised by the CLI session id that `watch --session`
# recorded, which is the transcript's file name.
is_scheduled() {
  [[ -n "${1:-}" ]] || return 1
  if [[ -s "$WATCHER_FILE" ]]; then
    local cli; cli="$(jq -r '.cli // empty' "$WATCHER_FILE" 2>/dev/null)"
    [[ -n "$cli" && "$(basename "$1" .jsonl)" == "$cli" ]] && return 0
  fi
  [[ -f "$1" ]] && head -c 8192 "$1" 2>/dev/null | grep -q '<scheduled-task'
}

# phases_done FILE — number of task sections (## / ### headings) whose tasks are all checked.
phases_done() {
  awk '
    /^#{2,3} / { if (n > 0 && n == d) p++; n = 0; d = 0; next }
    /^[[:space:]]*[-*] \[[ xX]\]/ { n++; if ($0 ~ /\[[xX]\]/) d++ }
    END { if (n > 0 && n == d) p++; print p + 0 }' "$1" 2>/dev/null
}

freshness_on() { [[ "$(config | jq -r '.freshness.enabled')" == "true" ]]; }

# sweep_cron -> cron expression for sweepMinutes, or fails on an interval cron cannot express.
sweep_cron() {
  local n; n="$(config | jq -r '.freshness.sweepMinutes')"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) || die "sweepMinutes must be a positive integer, got: $n"
  if (( n < 60 )); then printf '*/%s * * * *\n' "$n"
  elif (( n % 60 == 0 && n <= 1440 )); then printf '0 */%s * * *\n' "$((n / 60))"
  else die "sweepMinutes=$n: use 1-59 or a whole number of hours"; fi
}

# ── Cache ────────────────────────────────────────────────────────────────────
cache_file() { printf '%s/%s.json' "$CACHE_DIR" "$1"; }

read_cache() {
  local f; f="$(cache_file "$1")"
  if [[ -s "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then cat "$f"; else echo '{}'; fi
}

# merge_cache SESSION JQ_FILTER [jq args...]
merge_cache() {
  local session="$1" filter="$2"; shift 2
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  local f tmp; f="$(cache_file "$session")"; tmp="$f.$$"
  read_cache "$session" | jq "$@" "$filter" >"$tmp" 2>/dev/null && mv "$tmp" "$f"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ── Helpers ──────────────────────────────────────────────────────────────────
# run_bounded SECS CMD... — print CMD stdout; fail on timeout or error.
run_bounded() {
  local secs="$1"; shift
  local out; out="$(mktemp)" || return 1
  "$@" >"$out" 2>/dev/null &
  local pid=$! ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( ticks >= secs * 10 )); then
      kill "$pid" 2>/dev/null; rm -f "$out"; return 1
    fi
    sleep 0.1; ticks=$((ticks + 1))
  done
  wait "$pid"; local rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

default_branch() {
  local ref b
  ref="$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  [[ -n "$ref" ]] && { printf '%s' "${ref#origin/}"; return; }
  for b in main master develop; do
    git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$b" && { printf '%s' "$b"; return; }
  done
  printf 'main'
}

# resolve_slug ROOT SLUG — the slug the spec folder has NOW. A renamed spec
# (git mv specs/042-webhook specs/042-webhook-202) keeps its number, so a
# missing slug is followed through its NNN prefix. Empty when the folder is
# gone, or when two folders share the number (never guess between them).
resolve_slug() {
  local root="$1" slug="$2" num d hits=()
  [[ -n "$slug" ]] || return 0
  [[ -n "$(spec_dir "$root" "$slug")" ]] && { printf '%s' "$slug"; return; }
  num="${slug%%-*}"; [[ "$num" =~ ^[0-9]{3}$ ]] || return 0
  for d in "$root"/specs/"$num"-* "$root"/specs/archived/"$num"-* "$root"/specs/archive/"$num"-*; do
    [[ -d "$d" ]] && hits+=("$(basename "$d")")
  done
  (( ${#hits[@]} == 1 )) && printf '%s' "${hits[0]}"
}

# spec_dir ROOT SLUG — the spec folder, live or archived; empty when absent.
spec_dir() {
  local d
  for d in "$1/specs/$2" "$1/specs/archived/$2" "$1/specs/archive/$2"; do
    [[ -d "$d" ]] && { printf '%s' "$d"; return; }
  done
}

count_tasks() { # FILE -> "done total"
  local done total
  done="$(grep -cE '^[[:space:]]*[-*] \[[xX]\]' "$1" 2>/dev/null)" || done=0
  total="$(grep -cE '^[[:space:]]*[-*] \[[ xX]\]' "$1" 2>/dev/null)" || total=0
  printf '%s %s' "$done" "$total"
}

# pr_lookup ROOT SELECTOR SESSION -> JSON {number,state} or empty.
pr_lookup() {
  local root="$1" sel="$2" session="$3" now cached out
  [[ "$GH_ENABLED" == "1" ]] && command -v gh >/dev/null 2>&1 || return 0
  now="$(date +%s)"
  cached="$(read_cache "$session" | jq -c --arg sel "$sel" --argjson now "$now" --argjson ttl "$GH_TTL" \
    'select(.gh.sel == $sel and ($now - (.gh.at // 0)) < $ttl) | .gh.pr')"
  if [[ -n "$cached" ]]; then [[ "$cached" != "null" ]] && printf '%s' "$cached"; return 0; fi
  out="$(cd "$root" && run_bounded "$GH_TIMEOUT" gh pr view "$sel" --json number,state)" || out=""
  out="$(printf '%s' "$out" | jq -c '{number, state}' 2>/dev/null)" || out=""
  merge_cache "$session" '.gh = {sel: $sel, at: $now, pr: ($pr | if . == "" then null else fromjson end)}' \
    --arg sel "$sel" --argjson now "$now" --arg pr "$out"
  printf '%s' "$out"
}

# transcript_scan FILE -> JSON {slug, speckit, title}
#   slug    — last spec folder the session wrote into (Write/Edit/MultiEdit)
#   speckit — a /speckit.* command was typed in this session
#   title   — the session's current title as the app recorded it
transcript_scan() {
  local t="$1"
  [[ -n "$t" && -f "$t" ]] || { echo '{"slug":"","speckit":false,"title":""}'; return; }
  local slug speckit title
  slug="$(grep -E 'specs/(archived?/)?[0-9]{3}-' "$t" 2>/dev/null | jq -r '
      select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and (.name | test("^(Write|Edit|MultiEdit|NotebookEdit)$")))
      | (.input.file_path // .input.notebook_path // "")
      | (capture("specs/(archived?/)?(?<s>[0-9]{3}-[A-Za-z0-9._-]+)/") | .s)?' 2>/dev/null | tail -1)"
  speckit=false
  grep -E '"type":"user"' "$t" 2>/dev/null | grep -qE '<command-name>/?speckit\.' && speckit=true
  title="$(grep -E '"type":"custom-title"' "$t" 2>/dev/null | tail -1 | jq -r '.customTitle // ""' 2>/dev/null)"
  jq -n --arg slug "$slug" --argjson speckit "$speckit" --arg title "$title" \
    '{slug: $slug, speckit: $speckit, title: $title}'
}

# last_message TRANSCRIPT [FILE] — the last assistant text of the turn.
last_message() {
  if [[ -n "${2:-}" && -s "$2" ]]; then cat "$2"; return; fi
  [[ -n "$1" && -f "$1" ]] || return 0
  grep -E '"type":"assistant"' "$1" 2>/dev/null | tail -n 40 \
    | jq -rs '[.[] | .message.content[]? | select(.type == "text") | .text] | last // ""' 2>/dev/null
}

# ── Facts ────────────────────────────────────────────────────────────────────
facts() {
  local repo="$1" session="$2" transcript="$3" lastfile="$4"
  local root branch base cache
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || root="$repo"
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
  base="$(default_branch "$root")"
  cache="$(read_cache "$session")"
  [[ -z "$transcript" ]] && transcript="$(printf '%s' "$cache" | jq -r '.transcript // empty')"

  local scan; scan="$(transcript_scan "$transcript")"

  # Mode and spec slug: sticky cache, then branch, then transcript.
  local mode reason slug=""
  mode="$(printf '%s' "$cache" | jq -r '.mode // "free"')"
  slug="$(printf '%s' "$cache" | jq -r '.spec // empty')"
  reason="$(printf '%s' "$cache" | jq -r '.modeReason // "no spec-kit signal"')"
  local bslug=""
  [[ "$branch" =~ ([0-9]{3}-[A-Za-z0-9._-]+) ]] && bslug="${BASH_REMATCH[1]}"
  local tslug; tslug="$(resolve_slug "$root" "$(printf '%s' "$scan" | jq -r '.slug')")"
  bslug="$(resolve_slug "$root" "$bslug")"
  # A cached slug follows a renamed folder too; it stays as-is when unresolved.
  local cslug; cslug="$(resolve_slug "$root" "$slug")"; [[ -n "$cslug" ]] && slug="$cslug"
  if [[ -n "$tslug" ]]; then
    mode="spec"; slug="$tslug"; reason="session wrote into specs/$tslug/"
  elif [[ -n "$bslug" ]]; then
    mode="spec"; slug="$bslug"; reason="branch $branch names specs/$bslug/"
  elif [[ "$mode" != "spec" && "$(printf '%s' "$scan" | jq -r '.speckit')" == "true" ]]; then
    mode="spec"; reason="a /speckit.* command ran in this session"
  fi

  # Spec stage.
  local dir="" stage="" done=0 total=0
  [[ -n "$slug" ]] && dir="$(spec_dir "$root" "$slug")"
  if [[ -n "$dir" ]]; then
    case "$dir" in */archived/*|*/archive/*) stage="done" ;; esac
    if [[ -f "$dir/tasks.md" ]]; then read -r done total <<<"$(count_tasks "$dir/tasks.md")"; fi
    if [[ -z "$stage" ]]; then
      if [[ -f "$dir/tasks.md" ]]; then
        if (( total > 0 && done == total )); then stage="done"; else stage="implement"; fi
      elif [[ -f "$dir/plan.md" ]]; then stage="split"
      elif grep -q '\[NEEDS CLARIFICATION' "$dir/spec.md" 2>/dev/null; then stage="clarify"
      elif [[ -f "$dir/spec.md" ]]; then stage="plan"
      else stage="clarify"; fi
    fi
  fi

  # Git.
  local dirty ahead=0 upstream=false merged=false
  dirty="$(git -C "$root" status --porcelain 2>/dev/null | grep -cv '\.DS_Store$')" || dirty=0
  if git -C "$root" rev-parse --verify --quiet "@{upstream}" >/dev/null 2>&1; then
    upstream=true
    ahead="$(git -C "$root" rev-list --count "@{upstream}..HEAD" 2>/dev/null)" || ahead=0
  elif [[ -n "$branch" && "$branch" != "$base" ]]; then
    ahead="$(git -C "$root" rev-list --count "origin/$base..HEAD" 2>/dev/null)" || ahead=0
  fi
  # A pushed branch whose tip origin/<base> already contains. Stale until the
  # next fetch; covers forges without gh (Bitbucket) and fast-forward merges.
  if [[ "$upstream" == "true" && -n "$branch" && "$branch" != "$base" ]] \
     && git -C "$root" merge-base --is-ancestor HEAD "origin/$base" 2>/dev/null; then
    merged=true
  fi

  # Pull request: the branch's, or the one remembered for this session.
  local sel="" prj=""
  if [[ -n "$branch" && "$branch" != "$base" ]]; then sel="$branch"
  else sel="$(printf '%s' "$cache" | jq -r '.pr // empty')"; fi
  [[ -n "$sel" ]] && prj="$(pr_lookup "$root" "$sel" "$session")"
  [[ -z "$prj" ]] && prj="null"

  # Turn ending.
  local last question=false
  last="$(last_message "$transcript" "$lastfile")"
  printf '%s' "$last" | sed -e 's/[[:space:]*_`)]*$//' | tail -c 2 | grep -q '?' && question=true

  merge_cache "$session" '.mode = $m | .modeReason = $r | .spec = (if $s == "" then .spec else $s end)
      | .transcript = (if $t == "" then .transcript else $t end)
      | .pr = (if $pr == null then .pr else ($pr.number | tostring) end)' \
    --arg m "$mode" --arg r "$reason" --arg s "$slug" --arg t "$transcript" --argjson pr "$prj"

  jq -n --arg mode "$mode" --arg reason "$reason" --arg slug "$slug" --arg stage "$stage" \
    --argjson done "$done" --argjson total "$total" --arg branch "$branch" --arg base "$base" \
    --argjson dirty "$dirty" --argjson ahead "$ahead" --argjson upstream "$upstream" \
    --argjson merged "$merged" --argjson pr "$prj" --argjson question "$question" \
    --arg title "$(printf '%s' "$scan" | jq -r '.title')" --arg root "$root" \
    --slurpfile tpl "$TEMPLATES" '
    {
      mode: $mode, modeReason: $reason, root: $root, currentTitle: $title,
      spec: (if $slug == "" then null else {slug: $slug, stage: $stage, done: $done, total: $total} end),
      git: {branch: $branch, base: $base, dirty: $dirty, ahead: $ahead, upstream: $upstream, mergedByAncestry: $merged},
      pr: $pr, endsWithQuestion: $question
    }
    | .suggested = (
        (if .pr.state == "OPEN" then ["to-merge"]
         elif .pr.state == "MERGED" or $merged then ["to-test", "to-close"]
         elif .pr.state == "CLOSED" then ["closed"]
         elif .spec.stage == "clarify" then ["to-clarify"]
         elif .spec.stage == "plan" then ["to-plan"]
         elif .spec.stage == "split" then ["to-split"]
         elif .spec.stage == "implement" then ["to-implement", "paused"]
         elif $dirty > 0 or $ahead > 0 then ["to-test", "to-ship"]
         elif $upstream and $branch != $base and .pr == null then ["to-merge", "to-ship"]
         else ["to-read"] end)
        | if $question then ["decide"] + (. - ["decide"]) else . end)
    | .allowed = [$tpl[0].statuses | to_entries[] | select((.value.modes | index($mode)) and .value.atStop != false) | .key]
    | .fingerprint = ({mode, s: .spec, d: ($dirty > 0), a: ($ahead > 0), pr, m: $merged, q: $question} | tojson)'
}

# ── Render ───────────────────────────────────────────────────────────────────
# render_title STATUS SUBJECT PR PROGRESS [DOT] — DOT is "fresh" (default) or
# "working"; "working" is always forced for the working status. No dot when
# freshness is off.
render_title() {
  local fresh=false; freshness_on && fresh=true
  jq -r --arg s "$1" --arg subj "$2" --arg pr "$3" --arg prog "$4" --arg l "$LANG_KEY" \
    --argjson fresh "$fresh" --arg kind "${5:-fresh}" '
    .statuses[$s] as $x
    | if $x == null then error("unknown status: \($s)") else . end
    | (if ($kind == "working" or $s == "working") then .freshness.workingDot else .freshness.levels[0].dot end) as $d
    | (if $fresh then "\($d) " else "" end) as $dot
    | .maxLength as $max
    | ($x.label[$l] // $x.label.en)
      | gsub("\\{pr\\}"; (if $pr == "" then "" else " #\($pr)" end))
      | gsub("\\{progress\\}"; (if $prog == "" then "" else " \($prog)" end))
    | . as $label
    | ($max - ($label | length) - 5 - ($dot | length)) as $room
    | (if ($subj | length) > $room and $room > 1 then ($subj[0:($room - 1)] + "…") else $subj end) as $sub
    | "\($dot)\($x.icon) \($label) · \($sub)"
  ' "$TEMPLATES"
}

# render_activity KEY SUBJECT PROGRESS — "🔵 🛠️ Coding 5/14 · 295-parent-acts".
render_activity() {
  local fresh=false; freshness_on && fresh=true
  jq -r --arg k "$1" --arg subj "$2" --arg prog "$3" --argjson fresh "$fresh" --arg l "$LANG_KEY" '
    .activities[$k] as $a
    | if $a == null then error("unknown activity: \($k)") else . end
    | (if $fresh then "\(.freshness.workingDot) " else "" end) as $dot
    | (($a.label[$l] // $a.label.en) | gsub("\\{progress\\}"; (if $prog == "" then "" else " \($prog)" end))) as $label
    | (.maxLength - ($label | length) - 5 - ($dot | length)) as $room
    | (if ($subj | length) > $room and $room > 1 then ($subj[0:($room - 1)] + "…") else $subj end) as $sub
    | "\($dot)\($a.icon) \($label) · \($sub)"
  ' "$TEMPLATES"
}

# redot TITLE DOT — TITLE with any leading age/working dot replaced by DOT
# (DOT empty: dot removed).
redot() {
  jq -rn --arg t "$1" --arg d "$2" --slurpfile tpl "$TEMPLATES" '
    ([$tpl[0].freshness.levels[].dot, $tpl[0].freshness.workingDot] | map(. + " ")) as $dots
    | (reduce $dots[] as $p ($t; ltrimstr($p))) as $base
    | if $d == "" then $base else "\($d) \($base)" end'
}

# pr_merged CWD BRANCH — prints "merged" (or the PR number) when BRANCH's work
# reached the base branch; nothing otherwise. GitHub: gh pr view. Any other
# forge (Bitbucket): fetch origin/<base>, then git ancestry, so a merge is
# seen without the app's GitHub-only PR bar. Every network call is bounded.
pr_merged() {
  local cwd="$1" branch="$2" base out
  [[ -n "$cwd" && -d "$cwd" && -n "$branch" ]] || return 0
  git -C "$cwd" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 || return 0
  if [[ "$GH_ENABLED" == "1" ]] && command -v gh >/dev/null 2>&1 \
     && git -C "$cwd" remote get-url origin 2>/dev/null | grep -q 'github\.com'; then
    out="$(cd "$cwd" && run_bounded "$GH_TIMEOUT" gh pr view "$branch" --json state,number)" || out=""
    printf '%s' "$out" | jq -r 'select(.state == "MERGED") | .number' 2>/dev/null
    return 0
  fi
  base="$(default_branch "$cwd")"
  [[ "$branch" != "$base" ]] || return 0
  git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1 || return 0
  run_bounded 10 git -C "$cwd" fetch -q origin "$base" >/dev/null || true
  git -C "$cwd" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/origin/$base" 2>/dev/null && echo merged
  return 0
}

# merged_overrides FILE — {sessionId: new base title} for "to-merge" sessions
# whose PR is now merged: "🔀 To merge #12 · x" becomes "🏁 Merged #12 · x".
merged_overrides() {
  local ov='{}' id cwd branch base hit pr subj title
  local icon; icon="$(jq -r '.statuses["to-merge"].icon' "$TEMPLATES")"
  while IFS=$'\t' read -r id cwd branch base; do
    hit="$(pr_merged "$cwd" "$branch")"
    [[ -n "$hit" ]] || continue
    pr=""; [[ "$hit" =~ ^[0-9]+$ ]] && pr="$hit"
    [[ -z "$pr" && "$base" =~ \#([0-9]+) ]] && pr="${BASH_REMATCH[1]}"
    subj="${base#* · }"
    title="$(redot "$(render_title merged "$subj" "$pr" "")" "")" || continue
    ov="$(jq -c --arg k "$id" --arg v "$title" '. + {($k): $v}' <<<"$ov")"
  done < <(jq -r --arg icon "$icon" --slurpfile tpl "$TEMPLATES" '
    ([$tpl[0].freshness.levels[].dot, $tpl[0].freshness.workingDot] | map(. + " ")) as $dots
    | (if type == "array" then . else (.sessions // []) end)[]
    | select(.isArchived != true and .isRunning != true and (.title | type) == "string")
    | (reduce $dots[] as $p (.title; ltrimstr($p))) as $base
    | select($base | startswith($icon + " "))
    | [.sessionId, (.cwd // ""), (.branch // ""), $base] | @tsv' "$1")
  printf '%s' "$ov"
}

# sweep FILE — FILE is list_sessions output. Prints one {sessionId,title} line
# per session whose age dot is stale, or whose "to-merge" PR got merged. Only
# titles built from the templates are touched; running and archived sessions
# are skipped. With freshness off, the dots are stripped instead, so turning
# the feature off cleans the sidebar.
sweep() {
  local fresh=false; freshness_on && fresh=true
  local ov; ov="$(merged_overrides "$1")"; [[ -n "$ov" ]] || ov='{}'
  jq -c --argjson now "$(date +%s)" --argjson fresh "$fresh" --argjson ov "$ov" --slurpfile tpl "$TEMPLATES" '
    ($tpl[0].freshness.levels) as $levels
    | ([$levels[].dot, $tpl[0].freshness.workingDot] | map(. + " ")) as $dots
    | ([$tpl[0].statuses[].icon] + [$tpl[0].activities | to_entries[] | select(.key | startswith("$") | not) | .value.icon]) as $icons
    | (if type == "array" then . else (.sessions // []) end)[]
    | select(.isArchived != true and .isRunning != true and (.title | type) == "string")
    | .title as $t
    | ($ov[.sessionId] // (reduce $dots[] as $p ($t; ltrimstr($p)))) as $base
    | select(any($icons[]; . as $i | $base | startswith($i)))
    | ((.lastActivityAt // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) as $at
    | select($at != null)
    | (($now - $at) / 60) as $age
    | (first($levels[] | select(.belowMinutes == null or $age < .belowMinutes)) | .dot) as $dot
    | (if $fresh then "\($dot) \($base)" else $base end) as $new
    | select($new != $t)
    | {sessionId, title: $new}
  ' "$1"
}

# older_only SNAPSHOT — filters sweep lines on stdin, keeping a rename only
# when its dot is older than the current one (or the title loses its dot).
# A prompt bumps lastActivityAt before the working hook re-titles the session,
# so a 🟡 title can briefly look 🟢-fresh; turning a dot younger is the Stop
# hook's job, and a watcher wake for it would be wasted.
older_only() {
  jq -c --slurpfile snap "$1" --slurpfile tpl "$TEMPLATES" '
    ([$tpl[0].freshness.workingDot] + [$tpl[0].freshness.levels[].dot]) as $dots
    | (reduce ($snap[0][]) as $s ({}; .[$s.sessionId] = $s.title)) as $cur
    | def rank($t): [range(0; $dots | length) as $i | select($t | startswith($dots[$i] + " ")) | $i] | first // null;
      rank($cur[.sessionId] // "") as $old | rank(.title) as $new
    | select($old == null or $new == null or $new > $old)'
}

# snapshot [DAYS] — a list_sessions-shaped array read from the desktop app's
# own session files (one local_*.json per session), with no agent involved.
# The app keeps titles in memory, so these files are read-only for us: writing
# a title there changes nothing in the sidebar. Archived sessions are dropped
# before jq parses anything. Scheduled-task runs stay: the working hook titles
# them too ("🟠 ✅ Closed · Balayage pastilles"), so their dots must age.
# DAYS limits the scan to files modified within that many days. The
# files carry no isRunning flag, so a working-dot title active in the last
# 5 minutes counts as running; a crashed turn still ages past that. The app
# flushes lastActivityAt late: a file read 10:48:10 while get_session said
# 10:48:19.7, so 15 s are added to keep a dot from turning early. A
# snapshot is a trigger, never the authority.
snapshot() {
  local days="${1:-}" wdot; wdot="$(jq -r '.freshness.workingDot' "$TEMPLATES")"
  [[ -d "$APP_DIR" ]] || { echo '[]'; return 0; }
  {
    if [[ -n "$days" ]]; then
      find "$APP_DIR" -type f -name 'local_*.json' -mtime "-$days" -print0
    else
      find "$APP_DIR" -type f -name 'local_*.json' -print0
    fi
  } 2>/dev/null \
    | xargs -0 grep -L '"isArchived":true' 2>/dev/null \
    | tr '\n' '\0' \
    | xargs -0 jq -c --arg w "$wdot " --argjson now "$(date +%s)" 'select(.title | type == "string")
      | ((.lastActivityAt // 0) / 1000 | floor | . + 15) as $at
      | {sessionId, title, cwd, branch, isArchived: (.isArchived // false), lastActivityAt: ($at | todate),
         isRunning: ((.title | startswith($w)) and ($now - $at) < 300)}' 2>/dev/null \
    | jq -s .
  # grep -L exits 1 when no file is archived; under pipefail that would fail a
  # snapshot whose output is fine.
  return 0
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd="${1:-}"; [[ $# -gt 0 ]] && shift
repo="$(pwd)"; session=""; subject=""; pr=""; progress=""; status_arg=""
transcript=""; lastfile=""; mode_arg=""; sessions_file=""; days=""; interval=60; once=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --progress) progress="$2"; shift 2 ;;
    --transcript) transcript="$2"; shift 2 ;;
    --last-message-file) lastfile="$2"; shift 2 ;;
    --mode) mode_arg="$2"; shift 2 ;;
    --sessions) sessions_file="$2"; shift 2 ;;
    --days) days="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --once) once=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) status_arg="$1"; shift ;;
  esac
done

case "$cmd" in
  facts)
    [[ -n "$session" ]] || die "facts needs --session"
    facts "$repo" "$session" "$transcript" "$lastfile"
    ;;
  check)
    [[ -n "$session" ]] || die "check needs --session"
    state="$(facts "$repo" "$session" "$transcript" "$lastfile")" || exit 1
    fp="$(printf '%s' "$state" | jq -r '.fingerprint')"
    last="$(read_cache "$session" | jq -r '.asked // ""')"
    changed=false; [[ "$fp" != "$last" ]] && changed=true
    merge_cache "$session" '.asked = $fp' --arg fp "$fp"
    printf '%s' "$state" | jq --argjson c "$changed" '. + {changed: $c}'
    ;;
  set)
    [[ -n "$session" && -n "$status_arg" ]] || die "set needs STATUS and --session"
    state="$(facts "$repo" "$session" "" "")" || exit 1
    mode="$(printf '%s' "$state" | jq -r '.mode')"
    jq -e --arg s "$status_arg" --arg m "$mode" '.statuses[$s].modes | index($m)' "$TEMPLATES" >/dev/null \
      || die "status '$status_arg' is not allowed in $mode mode (see: list --mode $mode)"
    cache="$(read_cache "$session")"
    # Spec sessions are named by their spec, always: a --subject never replaces
    # the slug. Free sessions keep the agent's topic.
    if [[ "$mode" == "spec" ]]; then
      slug="$(printf '%s' "$state" | jq -r '.spec.slug // empty')"
      [[ -n "$slug" ]] && subject="$slug"
    fi
    [[ -z "$subject" ]] && subject="$(printf '%s' "$cache" | jq -r '.subject // empty')"
    [[ -z "$subject" ]] && subject="$(printf '%s' "$state" | jq -r 'if .git.branch != .git.base then .git.branch else "" end')"
    [[ -z "$subject" ]] && subject="$(basename "$(printf '%s' "$state" | jq -r '.root')")"
    prn="$(printf '%s' "$state" | jq -r '.pr.number // empty')"
    prog=""
    [[ "$status_arg" == "to-implement" ]] && prog="$(printf '%s' "$state" | jq -r 'if (.spec.total // 0) > 0 then "\(.spec.done)/\(.spec.total)" else "" end')"
    title="$(render_title "$status_arg" "$subject" "$prn" "$prog")" || exit 1
    merge_cache "$session" '.subject = $subj | .status = $s | .title = $t' \
      --arg subj "$subject" --arg s "$status_arg" --arg t "$title"
    if [[ "$title" == "$(printf '%s' "$state" | jq -r '.currentTitle')" ]]; then echo "UNCHANGED"; else echo "$title"; fi
    ;;
  gate)
    # Before an interactive question (AskUserQuestion): prints "deny" once so
    # the agent can rename the session to 'decide', then "allow". Never denies
    # twice within SESSION_TITLE_GATE_TTL seconds, even if the rename failed.
    # Either way the Stop fingerprint is cleared, so the turn that follows the
    # human's answer re-titles the session instead of keeping "À trancher".
    [[ -n "$session" ]] || die "gate needs --session"
    now="$(date +%s)"
    verdict="$(read_cache "$session" | jq -r --argjson now "$now" --argjson ttl "${SESSION_TITLE_GATE_TTL:-300}" '
      if .status == "decide" then "allow"
      elif ($now - (.gateAt // 0)) < $ttl then "allow"
      else "deny" end')"
    if [[ "$verdict" == "deny" ]]; then
      merge_cache "$session" '.gateAt = $now | .asked = ""' --argjson now "$now"
    else
      merge_cache "$session" '.gateAt = 0 | .asked = ""'
    fi
    echo "$verdict"
    ;;
  render)
    [[ -n "$status_arg" ]] || die "render needs STATUS"
    render_title "$status_arg" "${subject:-<subject>}" "$pr" "$progress"
    ;;
  list)
    jq -r --arg l "$LANG_KEY" --arg m "$mode_arg" '.statuses | to_entries[]
      | select($m == "" or (.value.modes | index($m)))
      | "\(.key)\t\(.value.icon) \(.value.label[$l] // .value.label.en)\t\(.value.modes | join(","))\t\(.value.next)"' \
      "$TEMPLATES" | column -t -s $'\t'
    ;;
  forget)
    [[ -n "$session" ]] || die "forget needs --session"
    rm -f "$(cache_file "$session")"
    ;;
  sweep)
    [[ -n "$sessions_file" && -f "$sessions_file" ]] || die "sweep needs --sessions FILE (list_sessions JSON)"
    sweep "$sessions_file"
    ;;
  snapshot) snapshot "$days" ;;
  watch)
    # The deterministic half of the sweep, with no agent: every --interval
    # seconds, snapshot + sweep, and print each {sessionId,title} rename not
    # printed before. Silence costs nothing, so a watcher session sleeps until
    # a dot really changes. A printed line is a hint: the woken agent runs the
    # authoritative sweep (list_sessions knows isRunning; the files do not).
    # The seen set persists in the cache and holds only the renames still
    # pending, so a declined rename or a session list_sessions reports as
    # running wakes nobody twice, even across --once relaunches.
    # The first pass ever scans every file (~8 s for 3,700 files), later
    # passes only files touched in the last 6 days: older ones are already ⚫
    # or carry no template title.
    # --once exits after the first pass that prints, for a background Bash
    # that wakes the agent on exit.
    [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 )) || die "--interval must be a positive integer"
    mkdir -p "$CACHE_DIR" 2>/dev/null || die "cannot create $CACHE_DIR"
    # Remember the watcher's session so the title hooks stay silent in it: its
    # turns are wakes, and a title judged at each one costs two extra steps.
    if [[ -n "$session" ]]; then
      own="$(find "$APP_DIR" -type f -name "$session.json" 2>/dev/null | head -1)"
      cli=""; [[ -n "$own" ]] && cli="$(jq -r '.cliSessionId // empty' "$own" 2>/dev/null)"
      jq -n --arg l "$session" --arg c "$cli" '{local: $l, cli: $c}' >"$WATCHER_FILE"
    fi
    snap="$CACHE_DIR/watch-snapshot.$$.json"; seen_file="$CACHE_DIR/watch-seen.txt"; scope=6
    [[ -f "$seen_file" ]] || { scope=""; : >"$seen_file"; }
    trap 'rm -f "$snap" "$seen_file.$$"' EXIT
    while :; do
      # Heartbeat: proves a watcher is alive to `watcher-status`, without ps
      # (absent from Git Bash on Windows).
      jq -n --argjson at "$(date +%s)" --argjson i "$interval" --arg l "$session" \
        '{at: $at, interval: $i, local: $l}' >"$HEARTBEAT_FILE" 2>/dev/null || true
      snapshot "$scope" >"$snap" || echo '[]' >"$snap"
      scope=6
      # The watcher's own session never counts: each wake re-titles it, so it
      # would turn 🟡 five minutes later and wake itself forever.
      sweep "$snap" 2>/dev/null | grep -v '^$' | { if [[ -n "$session" ]]; then grep -vF "\"$session\"" || true; else cat; fi; } \
        | older_only "$snap" >"$seen_file.$$"
      fresh_lines="$(grep -vxF -f "$seen_file" "$seen_file.$$")"
      [[ -s "$seen_file" ]] || fresh_lines="$(cat "$seen_file.$$")"
      mv "$seen_file.$$" "$seen_file"
      if [[ -n "$fresh_lines" ]]; then
        printf '%s\n' "$fresh_lines"
        (( once )) && exit 0
      fi
      sleep "$interval"
    done
    ;;
  watcher-status)
    # Is a freshness watcher alive on this machine? Read from the heartbeat
    # that each `watch` pass writes. Between a `--once` exit and its relaunch
    # the watcher agent renames for a minute or two and writes nothing, so the
    # heartbeat may lag up to 3 intervals plus 5 minutes before "down".
    #   off   — freshness disabled in the user config
    #   never — no watcher ever ran here (a fresh device)
    #   down  — the heartbeat stopped: the app quit, or the watcher was archived
    #   alive — a watch pass ran recently
    now="$(date +%s)"
    if ! freshness_on; then jq -nc '{state: "off"}'
    elif [[ ! -s "$HEARTBEAT_FILE" ]]; then jq -nc '{state: "never"}'
    else
      jq -c --argjson now "$now" '
        ($now - (.at // 0)) as $age
        | {state: (if $age <= (3 * (.interval // 60) + 300) then "alive" else "down" end),
           ageSeconds: $age, local: (.local // "")}' "$HEARTBEAT_FILE" 2>/dev/null \
        || jq -nc '{state: "down"}'
    fi
    ;;
  progress)
    # Mid-turn live counter: prints the new "🔨 À implémenter D/T" title when
    # the spec's tasks.md crossed a boundary since the last print (a finished
    # phase, or a finished task with progress.every = "task"); nothing otherwise.
    # Reads the cache and tasks.md only: no git, no gh, so it is cheap enough
    # for a PostToolUse hook.
    [[ -n "$session" ]] || die "progress needs --session"
    cache="$(read_cache "$session")"
    [[ "$(printf '%s' "$cache" | jq -r '.mode // ""')" == "spec" ]] || exit 0
    slug="$(printf '%s' "$cache" | jq -r '.spec // empty')"
    [[ -n "$slug" ]] || exit 0
    root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || root="$repo"
    slug="$(resolve_slug "$root" "$slug")"
    [[ -n "$slug" ]] || exit 0
    dir="$(spec_dir "$root" "$slug")"
    [[ -n "$dir" && -f "$dir/tasks.md" ]] || exit 0
    read -r done total <<<"$(count_tasks "$dir/tasks.md")"
    (( total > 0 && done < total )) || exit 0
    if [[ "$(config | jq -r '.progress.every')" == "task" ]]; then mark="$done"
    else mark="$(phases_done "$dir/tasks.md")"; fi
    [[ "$mark" == "$(printf '%s' "$cache" | jq -r '.progressMark // ""')" ]] && exit 0
    title="$(render_activity coding "$slug" "$done/$total")" || exit 1
    merge_cache "$session" '.progressMark = $m' --arg m "$mark"
    [[ "$title" == "$(printf '%s' "$cache" | jq -r '.progressTitle // ""')" ]] && exit 0
    # A mid-turn title: the status stays "working" so the Stop hook replaces it.
    merge_cache "$session" '.spec = $s | .progressTitle = $t' --arg s "$slug" --arg t "$title"
    echo "$title"
    ;;
  working)
    # A prompt just arrived: the human now waits on the agent. Remembers the
    # title to restore and prints {dot, subject, activities}: the agent picks
    # the activity that matches what it is about to do. subject is the spec
    # slug in spec mode (fixed), null in free mode (the agent writes a topic).
    [[ -n "$session" ]] || die "working needs --session"
    cache="$(read_cache "$session")"
    if [[ "$(printf '%s' "$cache" | jq -r '.status // ""')" != "working" ]]; then
      merge_cache "$session" '.prevTitle = (.title // "") | .prevStatus = (.status // "")'
    fi
    merge_cache "$session" '.status = "working"'
    slug="$(printf '%s' "$cache" | jq -r 'if .mode == "spec" then (.spec // "") else "" end')"
    root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || root="$repo"
    [[ -n "$slug" ]] && slug="$(resolve_slug "$root" "$slug")"
    prog=""
    if [[ -n "$slug" ]]; then
      dir="$(spec_dir "$root" "$slug")"
      if [[ -f "$dir/tasks.md" ]]; then
        read -r done total <<<"$(count_tasks "$dir/tasks.md")"
        (( total > 0 && done < total )) && prog="$done/$total"
      fi
    fi
    fresh=false; freshness_on && fresh=true
    jq -c --arg subj "$slug" --arg prog "$prog" --argjson fresh "$fresh" --arg l "$LANG_KEY" '
      {dot: (if $fresh then .freshness.workingDot else "" end),
       subject: (if $subj == "" then null else $subj end),
       activities: [.activities | to_entries[] | select(.key | startswith("$") | not)
         | "\(.value.icon) \((.value.label[$l] // .value.label.en) | gsub("\\{progress\\}"; (if $prog == "" then "" else " \($prog)" end))) — \(.value.when)"]}
    ' "$TEMPLATES"
    ;;
  restore)
    # Stop with unchanged facts after a working title. Spec mode: prints the
    # previous title with a fresh dot (its slug is not the agent's to choose).
    # Free mode: prints JUDGE — the topic may have moved, so the agent re-titles.
    # Prints nothing when there is nothing to restore.
    [[ -n "$session" ]] || die "restore needs --session"
    cache="$(read_cache "$session")"
    [[ "$(printf '%s' "$cache" | jq -r '.status // ""')" == "working" ]] || exit 0
    if [[ "$(printf '%s' "$cache" | jq -r '.mode // "free"')" != "spec" ]]; then echo "JUDGE"; exit 0; fi
    prev="$(printf '%s' "$cache" | jq -r '.prevTitle // ""')"
    [[ -n "$prev" ]] || exit 0
    if freshness_on; then title="$(redot "$prev" "$(jq -r '.freshness.levels[0].dot' "$TEMPLATES")")"
    else title="$(redot "$prev" "")"; fi
    merge_cache "$session" '.status = (.prevStatus // "") | .title = $t' --arg t "$title"
    echo "$title"
    ;;
  scheduled)
    is_scheduled "$transcript"
    ;;
  cron) sweep_cron ;;
  config)
    config | jq --arg f "$CONFIG_FILE" --arg c "$(sweep_cron)" '. + {file: $f, cron: $c}'
    ;;
  *) sed -n '2,56p' "$0"; exit 2 ;;
esac
