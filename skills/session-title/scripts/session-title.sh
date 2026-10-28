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
#   session-title.sh cron                           # cron expression of the freshness sweep
#   session-title.sh config                         # effective user config
#
# Freshness: every title carries an age dot ("🟡 🔀 À merger #12 · 042-webhook").
# `set` always renders 🟢 (the turn just ended); a scheduled task runs `sweep`
# to repaint idle sessions. Levels live in ../templates/titles.json; the sweep
# frequency lives in ONE user-level file, $SESSION_TITLE_CONFIG
# (default ~/.config/session-title/config.json):
#   { "freshness": { "enabled": true, "sweepMinutes": 5 } }
#
# Session mode:
#   spec — the session works on a spec-kit feature: the branch names an
#          existing specs/NNN-slug/, the transcript shows a Write/Edit under
#          specs/NNN-slug/ or a /speckit.* command. Sticky once detected.
#   free — everything else ("vibe coding", questions, investigations).
#
# Env knobs (all optional):
#   SESSION_TITLE_LANG=fr|en       label language (default fr)
#   SESSION_TITLE_TEMPLATES=PATH   template file override
#   SESSION_TITLE_CACHE=DIR        per-session cache (default ~/.cache/session-title)
#   SESSION_TITLE_GH=0             disable gh lookups
#   SESSION_TITLE_GH_TIMEOUT=4     seconds before a gh call is abandoned
#   SESSION_TITLE_GH_TTL=60        seconds a gh answer is reused
#   SESSION_TITLE_GATE_TTL=300     seconds the question gate stays open after a deny

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SESSION_TITLE_TEMPLATES:-$SCRIPT_DIR/../templates/titles.json}"
LANG_KEY="${SESSION_TITLE_LANG:-fr}"
CACHE_DIR="${SESSION_TITLE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/session-title}"
GH_ENABLED="${SESSION_TITLE_GH:-1}"
GH_TIMEOUT="${SESSION_TITLE_GH_TIMEOUT:-4}"
GH_TTL="${SESSION_TITLE_GH_TTL:-60}"
CONFIG_FILE="${SESSION_TITLE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/session-title/config.json}"

die() { printf 'session-title: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -f "$TEMPLATES" ]] || die "templates not found: $TEMPLATES"

# ── User config ──────────────────────────────────────────────────────────────
# Defaults deep-merged with the user file; a missing or broken file means defaults.
config() {
  local user='{}'
  [[ -s "$CONFIG_FILE" ]] && user="$(jq -c . "$CONFIG_FILE" 2>/dev/null)" || true
  [[ -n "$user" ]] || user='{}'
  jq -n --argjson u "$user" '{freshness: {enabled: true, sweepMinutes: 5}} * $u'
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
  local tslug; tslug="$(printf '%s' "$scan" | jq -r '.slug')"
  if [[ -n "$tslug" && -n "$(spec_dir "$root" "$tslug")" ]]; then
    mode="spec"; slug="$tslug"; reason="session wrote into specs/$tslug/"
  elif [[ -n "$bslug" && -n "$(spec_dir "$root" "$bslug")" ]]; then
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
    | .allowed = [$tpl[0].statuses | to_entries[] | select(.value.modes | index($mode)) | .key]
    | .fingerprint = ({mode, s: .spec, d: ($dirty > 0), a: ($ahead > 0), pr, m: $merged, q: $question} | tojson)'
}

# ── Render ───────────────────────────────────────────────────────────────────
render_title() { # STATUS SUBJECT PR PROGRESS — prefixed with the fresh dot when freshness is on
  local fresh=false; freshness_on && fresh=true
  jq -r --arg s "$1" --arg subj "$2" --arg pr "$3" --arg prog "$4" --arg l "$LANG_KEY" \
    --argjson fresh "$fresh" '
    .statuses[$s] as $x
    | if $x == null then error("unknown status: \($s)") else . end
    | (if $fresh then "\(.freshness.levels[0].dot) " else "" end) as $dot
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

# sweep FILE — FILE is list_sessions output. Prints one {sessionId,title} line
# per session whose age dot is stale. Only titles built from the templates are
# touched; running and archived sessions are skipped. With freshness off, the
# dots are stripped instead, so turning the feature off cleans the sidebar.
sweep() {
  local fresh=false; freshness_on && fresh=true
  jq -c --argjson now "$(date +%s)" --argjson fresh "$fresh" --slurpfile tpl "$TEMPLATES" '
    ($tpl[0].freshness.levels) as $levels
    | [$tpl[0].statuses[].icon] as $icons
    | (if type == "array" then . else (.sessions // []) end)[]
    | select(.isArchived != true and .isRunning != true and (.title | type) == "string")
    | .title as $t
    | (reduce ($levels[].dot + " ") as $p ($t; ltrimstr($p))) as $base
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

# ── Commands ─────────────────────────────────────────────────────────────────
cmd="${1:-}"; [[ $# -gt 0 ]] && shift
repo="$(pwd)"; session=""; subject=""; pr=""; progress=""; status_arg=""
transcript=""; lastfile=""; mode_arg=""; sessions_file=""
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
    # Spec sessions are named by their spec; free sessions keep the agent's topic.
    [[ -z "$subject" && "$mode" == "spec" ]] && subject="$(printf '%s' "$state" | jq -r '.spec.slug // empty')"
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
  cron) sweep_cron ;;
  config)
    config | jq --arg f "$CONFIG_FILE" --arg c "$(sweep_cron)" '. + {file: $f, cron: $c}'
    ;;
  *) sed -n '2,45p' "$0"; exit 2 ;;
esac
