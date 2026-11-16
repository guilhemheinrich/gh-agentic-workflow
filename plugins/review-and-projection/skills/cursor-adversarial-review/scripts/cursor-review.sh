#!/usr/bin/env bash
# cursor-review.sh — adversarial code review by a panel of models, through the
# Cursor CLI (`cursor-agent`), from the command line.
#
# The reviews go to files under --out; diagnostics go to stderr; the summary
# goes to stdout. That contract is what makes the script composable:
#
#   cursor-review.sh --diff main...HEAD -f specs/012/spec.md --panel 3 -s @adversarial.md
#
# Why this is not llm-ask.sh with a different URL: `cursor-agent` is an AGENT,
# not a completions endpoint. It reads files itself, from a workspace. So
# context is staged as FILES rather than embedded as text — which is both
# cheaper and what lets the reviewer cite file:line and pull in a neighbour it
# needs. Two consequences drive the whole design:
#
#   1. cursor-agent SILENTLY DISCARDS piped stdin (measured — §7 of SKILL.md).
#      `git diff | cursor-agent -p "review this"` reviews NOTHING and says so
#      confidently. This script materialises stdin into a file instead.
#   2. A reviewer pointed at your repo reviews your repo. Staging into an
#      ephemeral workspace makes the context boundary the review boundary.
#
# Requires cursor-agent + git (for --diff). jq only for --json. bash 3.2.
set -uo pipefail

readonly VERSION="1.0.0"

readonly EX_USAGE=1    # bad invocation
readonly EX_ENV=2      # cursor-agent missing, not logged in, no model
readonly EX_API=3      # a reviewer refused, or answered with nothing usable
readonly EX_TIMEOUT=4  # wall-clock budget exhausted

CURSOR_BIN="${CURSOR_REVIEW_BIN:-cursor-agent}"

MODELS=""                 # newline-delimited; bash 3.2 has no safe empty arrays
PANEL_N=0
EXCLUDE_VENDORS=""
AGENT_MODE="ask"          # ask | plan — both read-only, verified
SYSTEM=""
PROMPT_ARG=""
FILE_LIST=""
DIR_LIST=""
ADD_DIRS=""
DIFF_REF=""
DIFF_REQUESTED=0
IN_PLACE=0
OUT_DIR=""
KEEP_WS=0
JOBS="${CURSOR_REVIEW_JOBS:-3}"
TIMEOUT_S="${CURSOR_REVIEW_TIMEOUT_S:-900}"
BUDGET_S="${CURSOR_REVIEW_BUDGET_S:-}"
STDIN_MODE="auto"         # auto | always | never
STDIN_WAIT_S="${CURSOR_REVIEW_STDIN_WAIT_S:-5}"
WANT_JSON=0
DRY_RUN=0
DO_DOCTOR=0
DO_LIST=0
MODEL_FILTER=""
VERBOSE="${CURSOR_REVIEW_VERBOSE:-0}"
if [ "${CURSOR_REVIEW_NO_STDIN:-0}" = "1" ]; then STDIN_MODE="never"; fi

WS=""                     # staged workspace, set at stage time
WATCHDOG_PID=""
LANE_PIDS=""
PHASE="starting up"
PHASE_FILE=""

die()  { printf 'cursor-review: %s\n' "$1" >&2; exit "${2:-$EX_USAGE}"; }
warn() { printf 'cursor-review: %s\n' "$1" >&2; }
note() { [ "$VERBOSE" = "1" ] && printf 'cursor-review: %s\n' "$1" >&2; return 0; }

usage() {
  cat <<'EOF'
cursor-review.sh — adversarial review by a panel of models, via the Cursor CLI.

USAGE
  cursor-review.sh [options] "INSTRUCTION"
  git diff main...HEAD | cursor-review.sh [options] "INSTRUCTION"
  cursor-review.sh --doctor
  cursor-review.sh --list-models [FILTER]

CONTEXT (staged as files into an ephemeral workspace — that is the review boundary)
  -f, --file PATH       Stage a file, path preserved. Repeatable.
  -d, --dir PATH        Stage a directory, recursively. Repeatable.
      --diff [REF]      Stage `git diff REF` as review-context/diff.patch.
                        REF defaults to HEAD. Use main...HEAD for a branch.
      --changed [REF]   Stage the diff AND every file it touches, in full.
      --add-dir PATH    Extra read-only workspace root, passed to cursor-agent.
      --in-place        Do not stage; review inside the current repo.
      --stdin           Always read stdin. --no-stdin never does.

REVIEWER
  -m, --model ID        Model id. Repeatable — each one is a panel lane.
      --panel N         Pick N models, one per vendor, best-first. Excludes apply.
      --exclude-vendor V  Drop a vendor (anthropic, openai, google, xai,
                        moonshot, zhipu, cursor). Repeatable. Your own lineage.
      --mode ask|plan   Read-only agent mode (default ask). Never writes.
  -s, --system TEXT     Review charter, prepended. @path reads it from a file.

RUN
  -o, --out DIR         Where reviews land (default cursor-review-<stamp>/).
      --jobs N          Concurrent lanes (default 3).
      --timeout S       Per-lane wall clock (default 900).
      --budget S        Ceiling on the WHOLE run, armed at start-up. Exits 4.
      --json            Keep each lane's raw cursor-agent JSON result.
      --keep            Keep the staged workspace after the run.
      --dry-run         Stage, print the tree and the commands, call nothing.
      --doctor          Environment and ambient-context audit. Costs nothing.
      --list-models     Model ids from cursor-agent, optionally filtered.
  -v, --verbose         Staging and dispatch decisions on stderr.
  -h, --help            This text.        --version

EXIT
  0 every lane produced a review   1 bad invocation   2 environment
  3 a lane refused or returned nothing   4 budget exhausted
EOF
}

# ---------------------------------------------------------------- arg parsing

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)      [ $# -ge 2 ] || die "missing value for $1"; MODELS="$MODELS$2
"; shift 2 ;;
    --panel)         [ $# -ge 2 ] || die "missing value for $1"; PANEL_N="$2"; shift 2 ;;
    --exclude-vendor)[ $# -ge 2 ] || die "missing value for $1"; EXCLUDE_VENDORS="$EXCLUDE_VENDORS $2"; shift 2 ;;
    --mode)          [ $# -ge 2 ] || die "missing value for $1"; AGENT_MODE="$2"; shift 2 ;;
    -s|--system)     [ $# -ge 2 ] || die "missing value for $1"; SYSTEM="$2"; shift 2 ;;
    -f|--file)       [ $# -ge 2 ] || die "missing value for $1"; FILE_LIST="$FILE_LIST$2
"; shift 2 ;;
    -d|--dir)        [ $# -ge 2 ] || die "missing value for $1"; DIR_LIST="$DIR_LIST$2
"; shift 2 ;;
    --add-dir)       [ $# -ge 2 ] || die "missing value for $1"; ADD_DIRS="$ADD_DIRS$2
"; shift 2 ;;
    --diff)          DIFF_REQUESTED=1
                     case "${2:-}" in ''|-*) DIFF_REF="HEAD" ;; *) DIFF_REF="$2"; shift ;; esac
                     shift ;;
    --changed)       DIFF_REQUESTED=2
                     case "${2:-}" in ''|-*) DIFF_REF="HEAD" ;; *) DIFF_REF="$2"; shift ;; esac
                     shift ;;
    --in-place)      IN_PLACE=1; shift ;;
    --stdin)         STDIN_MODE="always"; shift ;;
    --no-stdin)      STDIN_MODE="never"; shift ;;
    -o|--out)        [ $# -ge 2 ] || die "missing value for $1"; OUT_DIR="$2"; shift 2 ;;
    --jobs)          [ $# -ge 2 ] || die "missing value for $1"; JOBS="$2"; shift 2 ;;
    --timeout)       [ $# -ge 2 ] || die "missing value for $1"; TIMEOUT_S="$2"; shift 2 ;;
    --budget)        [ $# -ge 2 ] || die "missing value for $1"; BUDGET_S="$2"; shift 2 ;;
    --json)          WANT_JSON=1; shift ;;
    --keep)          KEEP_WS=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --doctor)        DO_DOCTOR=1; shift ;;
    --list-models)   DO_LIST=1
                     case "${2:-}" in ''|-*) : ;; *) MODEL_FILTER="$2"; shift ;; esac
                     shift ;;
    -v|--verbose)    VERBOSE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    --version)       printf '%s\n' "$VERSION"; exit 0 ;;
    --)              shift; break ;;
    -*)              die "unknown option: $1" ;;
    *)               if [ -z "$PROMPT_ARG" ]; then PROMPT_ARG="$1"; else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[ $# -gt 0 ] && [ -z "$PROMPT_ARG" ] && { PROMPT_ARG="$1"; shift; }

case "$AGENT_MODE" in ask|plan) ;; *) die "--mode must be ask or plan (both read-only), got: $AGENT_MODE" ;; esac
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be at least 1"

# ------------------------------------------------------------ budget watchdog
# The per-lane --timeout only bounds a cursor-agent process. Everything before
# it — staging a directory off a stale mount, draining stdin — runs outside its
# reach. The budget is armed here, before anything can block, and names the
# phase it killed.
arm_budget() {
  if [ -z "$BUDGET_S" ]; then
    BUDGET_S=$(( TIMEOUT_S + STDIN_WAIT_S + 120 ))
  fi
  case "$BUDGET_S" in ''|*[!0-9]*) die "--budget must be a positive integer" ;; esac
  PHASE_FILE="$(mktemp "${TMPDIR:-/tmp}/cursor-review-phase.XXXXXX")"
  printf "%s" "$PHASE" > "$PHASE_FILE"
  local parent=$$
  # Poll rather than one long sleep: when the script dies from a signal that
  # skips the EXIT trap — SIGPIPE from `cursor-review.sh … | head` is the one
  # that bites — a sleeping watchdog would keep the caller's stderr open for
  # the whole budget and hang the pipeline. This notices within a second.
  ( exec >/dev/null 2>&3 3>&-
    i=0
    while [ "$i" -lt "$BUDGET_S" ]; do
      sleep 1
      kill -0 "$parent" 2>/dev/null || exit 0
      i=$(( i + 1 ))
    done
    printf 'cursor-review: budget of %ss exhausted while: %s\n' "$BUDGET_S" \
      "$(cat "$PHASE_FILE" 2>/dev/null || echo unknown)" >&2
    kill -TERM "-$parent" 2>/dev/null || kill -TERM "$parent" 2>/dev/null
  ) 3>&2 & WATCHDOG_PID=$!
  disown 2>/dev/null || true
}
set_phase() { PHASE="$1"; [ -n "$PHASE_FILE" ] && printf "%s" "$1" > "$PHASE_FILE" 2>/dev/null; note "phase: $1"; return 0; }

cleanup() {
  local rc=$?
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  [ -n "$PHASE_FILE" ] && rm -f "$PHASE_FILE" 2>/dev/null
  for _p in $LANE_PIDS; do kill "$_p" 2>/dev/null; done
  if [ -n "$WS" ] && [ "$KEEP_WS" = "0" ] && [ "$IN_PLACE" = "0" ]; then
    rm -rf "$WS" 2>/dev/null
  elif [ -n "$WS" ] && [ "$IN_PLACE" = "0" ]; then
    printf 'cursor-review: staged workspace kept at %s\n' "$WS" >&2
  fi
  exit $rc
}
trap cleanup EXIT
trap 'exit $EX_TIMEOUT' TERM

# ------------------------------------------------------------------- catalogue

need_cursor() {
  command -v "$CURSOR_BIN" >/dev/null 2>&1 \
    || die "$CURSOR_BIN not found on PATH — install the Cursor CLI, then run '$CURSOR_BIN login'" $EX_ENV
}

# Model ids as printed by `cursor-agent --list-models`, one per line.
catalogue() {
  "$CURSOR_BIN" --list-models 2>/dev/null \
    | sed -n 's/^\([a-z0-9][a-z0-9._-]*\) - .*/\1/p' \
    | grep -v '^auto$'
}

# Cursor exposes no benchmark scores, so vendor is inferred from the id prefix.
vendor_of() {
  case "$1" in
    claude-*)               echo anthropic ;;
    gpt-*|codex-*|o[0-9]-*) echo openai ;;
    gemini-*)               echo google ;;
    cursor-grok-*|grok-*)   echo xai ;;
    kimi-*)                 echo moonshot ;;
    glm-*)                  echo zhipu ;;
    composer-*)             echo cursor ;;
    *)                      echo other ;;
  esac
}

vendor_excluded() {
  local v="$1" x
  for x in $EXCLUDE_VENDORS; do [ "$x" = "$v" ] && return 0; done
  return 1
}

# One flagship per vendor, best-first, resolved against the LIVE catalogue so a
# retired id is skipped rather than hardcoded into a 404. Patterns are ordered:
# the first that matches a live id wins for that vendor.
readonly PANEL_PREFERENCE='
openai|^gpt-5\.6-sol-high$|^gpt-5\.6-sol-medium$|^gpt-5\.3-codex-high$|^gpt-5\.3-codex$|^gpt-5\.4-high$|^gpt-5\.2$|^gpt-5\.4-mini-medium$
anthropic|^claude-opus-5-thinking-high$|^claude-opus-5-high$|^claude-sonnet-5-thinking-high$|^claude-4\.5-sonnet-thinking$
google|^gemini-3\.7-flash-high$|^gemini-3\.1-pro$|^gemini-3\.6-flash-high$|^gemini-3-flash$
xai|^cursor-grok-4\.6-high$|^cursor-grok-4\.5-high$
moonshot|^kimi-k3-max$|^kimi-k3-high$|^kimi-k2\.7-code$|^kimi-k3-low$
zhipu|^glm-5\.2-max$|^glm-5\.2-high$
cursor|^composer-2\.5$
'

pick_panel() {
  local want="$1" live picked=0 line vendor pats pat hit
  live="$(catalogue)"
  [ -n "$live" ] || die "cursor-agent returned no models — is it logged in? run '$CURSOR_BIN status'" $EX_ENV
  printf '%s\n' "$PANEL_PREFERENCE" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    vendor="${line%%|*}"
    pats="${line#*|}"
    vendor_excluded "$vendor" && continue
    hit=""
    local IFS='|'
    for pat in $pats; do
      hit="$(printf '%s\n' "$live" | grep -m1 -E "$pat" || true)"
      [ -n "$hit" ] && break
    done
    unset IFS
    [ -n "$hit" ] || continue
    printf '%s\n' "$hit"
  done | head -n "$want"
}

# ---------------------------------------------------------------------- doctor

doctor() {
  printf 'cursor-review %s\n\n' "$VERSION"
  local bin; bin="$(command -v "$CURSOR_BIN" 2>/dev/null || true)"
  printf 'cursor-agent : %s\n' "${bin:-MISSING}"
  [ -n "$bin" ] && printf 'version      : %s\n' "$("$CURSOR_BIN" --version 2>/dev/null | head -1)"
  printf 'git          : %s\n' "$(command -v git 2>/dev/null || echo MISSING)"
  printf 'jq           : %s\n' "$(command -v jq 2>/dev/null || echo 'MISSING (needed only for --json)')"
  if [ -n "$bin" ]; then
    printf 'auth         : %s\n' "$("$CURSOR_BIN" status 2>&1 | head -1 | sed 's/^[^A-Za-z]*//')"
    printf 'models       : %s reachable\n' "$(catalogue | wc -l | tr -d ' ')"
  fi
  printf '\nambient context injected into EVERY review (not suppressible):\n'
  local cfg="${HOME}/.cursor"
  if [ -f "$cfg/hooks.json" ]; then
    printf '  hooks      : %s — hook events below run for every lane\n' "$cfg/hooks.json"
    grep -oE '"[a-zA-Z]+":' "$cfg/hooks.json" 2>/dev/null | tr -d '":' | grep -vE '^(version|hooks|command)$' | sed 's/^/               - /'
  else
    printf '  hooks      : none\n'
  fi
  local ns=0
  for d in "$cfg/skills" "$cfg/skills-cursor"; do
    [ -d "$d" ] && ns=$(( ns + $(find -L "$d" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ') ))
  done
  printf '  skills     : %s user-level SKILL.md, their names and descriptions are in the system prompt\n' "$ns"
  local nr=0
  [ -d "$cfg/rules" ] && nr=$(find -L "$cfg/rules" -name '*.mdc' 2>/dev/null | wc -l | tr -d ' ')
  printf '  rules      : %s user-level .mdc (only alwaysApply ones are injected)\n' "$nr"
  if [ -f "$cfg/mcp.json" ]; then
    printf '  mcp        : %s — servers here are offered to the reviewer as tools\n' "$cfg/mcp.json"
  fi
  printf '\nA staged review (the default) keeps your REPO out of the reviewer context.\n'
  printf 'It cannot keep the entries above out. Scope the charter accordingly.\n'
}

# --------------------------------------------------------------------- staging

# Absolute, symlink-free path without requiring GNU readlink -f (macOS lacks it).
abspath() {
  local p="$1" d b
  if [ -d "$p" ]; then ( cd "$p" 2>/dev/null && pwd -P ); return; fi
  d="$(dirname "$p")"; b="$(basename "$p")"
  ( cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b" )
}

REPO_ROOT=""
resolve_repo_root() {
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd -P)"
}

STAGED_MANIFEST=""

# Stage one file, preserving its path relative to the repo root so that a
# file:line citation from the reviewer still points at a real place in YOUR
# tree. A path outside the repo is flattened under external/.
stage_file() {
  local src="$1" abs rel dest
  [ -e "$src" ] || die "no such file: $src"
  [ -d "$src" ] && die "$src is a directory — use -d/--dir"
  [ -r "$src" ] || die "unreadable file: $src"
  abs="$(abspath "$src")"
  case "$abs" in
    "$REPO_ROOT"/*) rel="${abs#"$REPO_ROOT"/}" ;;
    *)              rel="external/$(basename "$abs")" ;;
  esac
  dest="$WS/$rel"
  mkdir -p "$(dirname "$dest")"
  cp "$abs" "$dest" || die "could not stage $src"
  STAGED_MANIFEST="$STAGED_MANIFEST- \`$rel\`
"
  note "staged file $rel"
}

stage_dir() {
  local src="$1" abs rel n
  [ -d "$src" ] || die "no such directory: $src"
  abs="$(abspath "$src")"
  case "$abs" in
    "$REPO_ROOT"/*) rel="${abs#"$REPO_ROOT"/}" ;;
    "$REPO_ROOT")   rel="." ;;
    *)              rel="external/$(basename "$abs")" ;;
  esac
  mkdir -p "$WS/$rel"
  # -L follows symlinks so a linked spec dir stages its contents, not the link.
  ( cd "$abs" && find -L . \
      -name .git -prune -o -name node_modules -prune -o -name .venv -prune \
      -o -type f -print ) \
    | while IFS= read -r f; do
        mkdir -p "$WS/$rel/$(dirname "$f")"
        cp "$abs/$f" "$WS/$rel/$f" 2>/dev/null
      done
  n="$(find "$WS/$rel" -type f | wc -l | tr -d ' ')"
  STAGED_MANIFEST="$STAGED_MANIFEST- \`$rel/\` ($n files)
"
  note "staged dir $rel ($n files)"
}

stage_diff() {
  command -v git >/dev/null 2>&1 || die "git not found, needed for --diff" $EX_ENV
  git rev-parse --git-dir >/dev/null 2>&1 || die "--diff needs a git repository" $EX_ENV
  mkdir -p "$WS/review-context"
  if ! git diff "$DIFF_REF" > "$WS/review-context/diff.patch" 2>"$WS/review-context/.differr"; then
    warn "git diff $DIFF_REF failed: $(head -1 "$WS/review-context/.differr")"
    die "bad --diff ref: $DIFF_REF"
  fi
  rm -f "$WS/review-context/.differr"
  if [ ! -s "$WS/review-context/diff.patch" ]; then
    die "git diff $DIFF_REF is empty — nothing to review"
  fi
  STAGED_MANIFEST="$STAGED_MANIFEST- \`review-context/diff.patch\` — output of \`git diff $DIFF_REF\`
"
  note "staged diff for $DIFF_REF"
  # --changed also stages every touched file IN FULL. A hunk without its
  # enclosing function is the main source of false positives: the reviewer
  # flags a variable as uninitialised that was initialised above the hunk.
  if [ "$DIFF_REQUESTED" = "2" ]; then
    local n=0 f
    while IFS= read -r f; do
      [ -f "$REPO_ROOT/$f" ] || continue
      mkdir -p "$WS/$(dirname "$f")"
      cp "$REPO_ROOT/$f" "$WS/$f" 2>/dev/null && n=$(( n + 1 ))
    done < <(git diff --name-only "$DIFF_REF")
    STAGED_MANIFEST="$STAGED_MANIFEST- $n changed file(s), in full, at their repository paths
"
    note "staged $n changed files in full"
  fi
}

# cursor-agent discards piped stdin without a word (measured). Rather than
# inherit that, drain it here and write it into the workspace as a file the
# reviewer can actually read.
stage_stdin() {
  local tmp="$WS/review-context/stdin.patch"
  mkdir -p "$WS/review-context"
  # POSIX gives an asynchronous command /dev/null as its standard input, so a
  # plain `cat > file &` drains nothing and silently stages an empty patch —
  # the exact failure this whole function exists to prevent. Hand the drain the
  # real descriptor explicitly.
  exec 3<&0
  if [ "$STDIN_MODE" = "always" ]; then
    cat <&3 > "$tmp"
  else
    # Bounded: an agent harness, CI runner or `ssh host cmd` hands a child an
    # idle pipe nobody will ever close, and that is indistinguishable up front
    # from a real one.
    cat <&3 > "$tmp" &
    local drain=$!
    local waited=0
    while kill -0 "$drain" 2>/dev/null && [ "$waited" -lt "$STDIN_WAIT_S" ]; do
      sleep 1; waited=$(( waited + 1 ))
    done
    if kill -0 "$drain" 2>/dev/null; then
      kill "$drain" 2>/dev/null; wait "$drain" 2>/dev/null
      exec 3<&-
      warn "stdin never reached EOF after ${STDIN_WAIT_S}s — dropped whole. Pass --no-stdin in a non-interactive caller."
      rm -f "$tmp"; return
    fi
    wait "$drain" 2>/dev/null
  fi
  exec 3<&-
  if [ -s "$tmp" ]; then
    STAGED_MANIFEST="$STAGED_MANIFEST- \`review-context/stdin.patch\` — piped in on standard input
"
    note "staged stdin ($(wc -c < "$tmp" | tr -d ' ') bytes)"
  else
    rm -f "$tmp"
  fi
}

write_manifest() {
  cat > "$WS/REVIEW-CONTEXT.md" <<EOF
# Review context

Every file below was staged for this review. **This list is the review
boundary**: do not report on anything outside it, and do not go looking for
files that are not here — they were withheld on purpose.

Paths are preserved relative to the repository root, so a \`file:line\`
citation you make here points at a real location in the author's tree.

$STAGED_MANIFEST
EOF
  note "wrote REVIEW-CONTEXT.md"
}

# ------------------------------------------------------------------- dispatch

build_prompt() {
  local sys="$SYSTEM"
  case "$sys" in
    @*) local p="${sys#@}"; [ -r "$p" ] || die "cannot read system prompt file: $p"; sys="$(cat "$p")" ;;
  esac
  if [ -n "$sys" ]; then printf '%s\n\n' "$sys"; fi
  printf 'Read REVIEW-CONTEXT.md first: it lists every file staged for this review and is the boundary of what you may report on.\n\n'
  if [ -n "$PROMPT_ARG" ]; then printf '%s\n' "$PROMPT_ARG"; fi
}

run_lane() {
  # Close every inherited fd: a lane writes to its own files, and a lane still
  # holding the caller's pipe is what makes `cursor-review.sh … | tail` hang
  # long after the script itself is gone.
  exec 0</dev/null 1>/dev/null 2>/dev/null
  local model="$1" prompt="$2" outfile="$3" jsonfile="$4"
  local rc
  if [ "$WANT_JSON" = "1" ]; then
    timeout "$TIMEOUT_S" "$CURSOR_BIN" -p --trust --mode "$AGENT_MODE" \
      --output-format json --model "$model" $ADD_DIR_FLAGS "$prompt" \
      </dev/null > "$jsonfile" 2>"$outfile.err"
    rc=$?
    if command -v jq >/dev/null 2>&1 && [ -s "$jsonfile" ]; then
      jq -r '.result // empty' "$jsonfile" > "$outfile" 2>/dev/null
    else
      cp "$jsonfile" "$outfile"
    fi
  else
    timeout "$TIMEOUT_S" "$CURSOR_BIN" -p --trust --mode "$AGENT_MODE" \
      --model "$model" $ADD_DIR_FLAGS "$prompt" \
      </dev/null > "$outfile" 2>"$outfile.err"
    rc=$?
  fi
  printf '%s\n' "$rc" > "$outfile.rc"
  return 0
}

# ------------------------------------------------------------------------ main

need_cursor
[ "$DO_DOCTOR" = "1" ] && { doctor; exit 0; }
if [ "$DO_LIST" = "1" ]; then
  if [ -n "$MODEL_FILTER" ]; then catalogue | grep -- "$MODEL_FILTER"; else catalogue; fi
  exit 0
fi

arm_budget
resolve_repo_root

# Resolve the panel.
if [ "$PANEL_N" != "0" ]; then
  case "$PANEL_N" in ''|*[!0-9]*) die "--panel must be a positive integer" ;; esac
  set_phase "resolving the panel"
  picked="$(pick_panel "$PANEL_N")"
  [ -n "$picked" ] || die "no model survived --exclude-vendor; try fewer exclusions" $EX_ENV
  MODELS="$MODELS$picked
"
fi
MODELS="$(printf '%s' "$MODELS" | grep -v '^$' | awk '!seen[$0]++')"
[ -n "$MODELS" ] || die "no model — pass -m ID (repeatable) or --panel N" $EX_ENV

n_models="$(printf '%s\n' "$MODELS" | wc -l | tr -d ' ')"

# Workspace.
if [ "$IN_PLACE" = "1" ]; then
  WS="$REPO_ROOT"
  [ -n "$FILE_LIST$DIR_LIST" ] && warn "--in-place ignores -f/-d: the whole repo is the workspace"
else
  WS="$(mktemp -d "${TMPDIR:-/tmp}/cursor-review.XXXXXX")" || die "cannot create a staging workspace" $EX_ENV
fi
set_phase "staging context"

if [ "$IN_PLACE" = "0" ]; then
  OLDIFS="$IFS"; IFS='
'
  for f in $FILE_LIST; do [ -n "$f" ] && stage_file "$f"; done
  for d in $DIR_LIST;  do [ -n "$d" ] && stage_dir  "$d"; done
  IFS="$OLDIFS"
  [ "$DIFF_REQUESTED" != "0" ] && stage_diff
  if [ "$STDIN_MODE" != "never" ] && [ ! -t 0 ]; then
    set_phase "reading stdin"; stage_stdin
  fi
  if [ -z "$STAGED_MANIFEST" ]; then
    die "nothing staged — pass -f, -d, --diff, or pipe a diff in (or use --in-place)"
  fi
  write_manifest
fi

ADD_DIR_FLAGS=""
OLDIFS="$IFS"; IFS='
'
for a in $ADD_DIRS; do [ -n "$a" ] && ADD_DIR_FLAGS="$ADD_DIR_FLAGS --add-dir $a"; done
IFS="$OLDIFS"

PROMPT="$(build_prompt)"

[ -n "$OUT_DIR" ] || OUT_DIR="cursor-review-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR" || die "cannot create output directory: $OUT_DIR"

# One line before anything can block, so a stalled run still says what it tried.
printf 'cursor-review: %s lane(s) [%s] · mode %s · %s · budget %ss\n' \
  "$n_models" "$(printf '%s' "$MODELS" | tr '\n' ' ')" "$AGENT_MODE" \
  "$([ "$IN_PLACE" = "1" ] && echo 'in-place' || echo "staged in $WS")" "$BUDGET_S" >&2

if [ "$DRY_RUN" = "1" ]; then
  printf 'workspace : %s\n' "$WS"
  printf 'out       : %s\n' "$OUT_DIR"
  printf 'mode      : %s (read-only)\n' "$AGENT_MODE"
  printf 'timeout   : %ss per lane, budget %ss for the run\n' "$TIMEOUT_S" "$BUDGET_S"
  printf '\nstaged tree:\n'
  ( cd "$WS" && find . -type f -not -name '.phase' | sed 's|^\./|  |' | sort )
  printf '\nprompt:\n'
  printf '%s\n' "$PROMPT" | sed 's/^/  /'
  printf '\ncommands:\n'
  printf '%s\n' "$MODELS" | while IFS= read -r m; do
    [ -n "$m" ] && printf '  (cd %s && %s -p --trust --mode %s --model %s%s "<prompt>" </dev/null)\n' \
      "$WS" "$CURSOR_BIN" "$AGENT_MODE" "$m" "$ADD_DIR_FLAGS"
  done
  KEEP_WS=0
  exit 0
fi

set_phase "dispatching $n_models lane(s)"
cd "$WS" || die "cannot enter workspace $WS" $EX_ENV

running=0
OLDIFS="$IFS"; IFS='
'
for m in $MODELS; do
  [ -n "$m" ] || continue
  safe="$(printf '%s' "$m" | tr -c 'A-Za-z0-9._-' '-')"
  out="$OLDPWD/$OUT_DIR/review-$safe.md"
  jsn="$OLDPWD/$OUT_DIR/review-$safe.json"
  case "$OUT_DIR" in /*) out="$OUT_DIR/review-$safe.md"; jsn="$OUT_DIR/review-$safe.json" ;; esac
  note "lane $m -> $out"
  run_lane "$m" "$PROMPT" "$out" "$jsn" &
  LANE_PIDS="$LANE_PIDS $!"
  running=$(( running + 1 ))
  if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
done
IFS="$OLDIFS"
wait

cd "$OLDPWD" 2>/dev/null || cd "$REPO_ROOT"

# ------------------------------------------------------------------- reporting

set_phase "collecting reviews"
fail=0
printf '\n'
OLDIFS="$IFS"; IFS='
'
for m in $MODELS; do
  [ -n "$m" ] || continue
  safe="$(printf '%s' "$m" | tr -c 'A-Za-z0-9._-' '-')"
  out="$OUT_DIR/review-$safe.md"
  rc="$(cat "$out.rc" 2>/dev/null || echo 1)"
  bytes=0; [ -f "$out" ] && bytes="$(wc -c < "$out" | tr -d ' ')"
  if [ "$rc" = "124" ]; then
    printf '%-34s TIMEOUT after %ss\n' "$m" "$TIMEOUT_S"; fail=$EX_TIMEOUT
  elif [ "$rc" != "0" ]; then
    printf '%-34s FAILED (exit %s) — %s\n' "$m" "$rc" "$(head -1 "$out.err" 2>/dev/null | cut -c1-90)"; [ "$fail" = "0" ] && fail=$EX_API
  elif [ "$bytes" -lt 20 ]; then
    printf '%-34s EMPTY — refusal or zero-token answer\n' "$m"; [ "$fail" = "0" ] && fail=$EX_API
  else
    printf '%-34s %6s bytes  %s\n' "$m" "$bytes" "$out"
  fi
  rm -f "$out.rc"
  [ -s "$out.err" ] || rm -f "$out.err"
done
IFS="$OLDIFS"

printf '\nreviews in %s/ — candidates, not a verdict. Verify each finding against the code.\n' "$OUT_DIR"
exit "$fail"
