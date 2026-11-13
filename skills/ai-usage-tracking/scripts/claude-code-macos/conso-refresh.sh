#!/bin/sh
# conso-refresh.sh - the slow half of `conso`: rebuild the precomputed cache. Run by the timer.
#
# Usage: conso-refresh.sh [-n] [-q] [--session SINCE UNTIL]
#   -n  offline: no usage API call and no snapshot (ccusage part only)
#   -q  quiet (timer): print nothing on success
#   --session SINCE UNTIL  print ccusage's per-session JSON (YYYY-MM-DD) on stdout, write no cache
#
# What it does (Docker only, transcripts mounted read-only):
#   1. Usage API (Claude Code's OAuth token, never printed): append one snapshot line to
#      $CONSO_STORE (default ~/.local/share/conso/extra.jsonl).
#   2. ccusage, PINNED and installed once into ~/.local/share/conso/ccusage-<version> (no npm fetch per
#      run), re-aggregates the last CONSO_OVERLAP_DAYS (default 14) days; older days stay from the cache.
#      First run, or unusable cache: the last CONSO_HISTORY_DAYS (default 90) days.
#   3. conso-merge.js merges it into cache.json (schema 1); written to a temp file, validated, then
#      renamed (atomic), mode 600.
# Env: CONSO_STORE, CONSO_CACHE, CLAUDE_PROJECTS_DIR, CCUSAGE_VERSION, CONSO_HISTORY_DAYS, CONSO_OVERLAP_DAYS.
set -eu
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
STORE=${CONSO_STORE:-$HOME/.local/share/conso/extra.jsonl}
DATA=$(dirname "$STORE")
CACHE=${CONSO_CACHE:-$DATA/cache.json}
PROJECTS=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}
VER=${CCUSAGE_VERSION:-20.0.50}
HISTORY=${CONSO_HISTORY_DAYS:-90}
OVERLAP=${CONSO_OVERLAP_DAYS:-14}
API=1
QUIET=0
SESSION=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n) API=0 ;;
    -q) QUIET=1 ;;
    --session) [ $# -ge 3 ] || { echo "--session needs SINCE UNTIL" >&2; exit 1; }
               SESSION=1; S_SINCE=$2; S_UNTIL=$3; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

say() { [ "$QUIET" = 1 ] || echo "$@" >&2; }
back() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 days ago" +%Y-%m-%d; }
command -v docker >/dev/null 2>&1 || { echo "conso: docker is required" >&2; exit 1; }
mkdir -p "$DATA"

# Pinned ccusage, installed once (the download that used to happen on every run).
PK="$DATA/ccusage-$VER"
if [ ! -x "$PK/node_modules/.bin/ccusage" ]; then
  say "conso: installing ccusage@$VER once (pinned, no download on later runs)..."
  mkdir -p "$PK"
  docker run --rm -v "$PK":/pk node:22-slim sh -c \
    "cd /pk && npm install --no-audit --no-fund --loglevel=error ccusage@$VER" >&2 \
    || { echo "conso: ccusage install failed" >&2; exit 1; }
fi

if [ "$SESSION" = 1 ]; then
  exec docker run --rm -v "$PROJECTS":/root/.claude/projects:ro -v "$PK":/pk:ro node:22-slim \
    /pk/node_modules/.bin/ccusage session --json --breakdown \
    --since "$(echo "$S_SINCE" | tr -d -)" --until "$(echo "$S_UNTIL" | tr -d -)"
fi

# One refresh at a time (timer + manual run); a lock older than 15 min is considered dead.
LOCK="$DATA/refresh.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK"
  else say "conso: a refresh is already running"; exit 0; fi
fi
TMP=$(mktemp "$DATA/.cache.XXXXXX")
trap 'rm -rf "$LOCK" "$TMP"' EXIT

# --- 1. Live usage snapshot (best effort) -------------------------------------
USAGE_JSON=
USAGE_ERR=
if [ "$API" = 1 ]; then
  CREDS=
  if command -v security >/dev/null 2>&1; then
    CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  fi
  [ -n "$CREDS" ] || { [ -f "$HOME/.claude/.credentials.json" ] && CREDS=$(cat "$HOME/.claude/.credentials.json"); } || true
  TOKEN=$(printf '%s' "$CREDS" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$TOKEN" ]; then
    USAGE_ERR="no Claude Code OAuth token found (log in with claude)"
  else
    RESP=$(curl -s -m 15 -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
      -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null || true)
    CODE=$(printf '%s' "$RESP" | tail -1)
    if [ "$CODE" = 200 ]; then
      USAGE_JSON=$(printf '%s' "$RESP" | sed '$d')
    else
      USAGE_ERR="usage endpoint answered HTTP ${CODE:-none} (expired token? run any claude command, then retry)"
    fi
  fi
  unset TOKEN CREDS RESP
  if [ -n "$USAGE_JSON" ]; then
    USED=$(printf '%s' "$USAGE_JSON" | sed -n 's/.*"used_credits": *\([0-9.]*\).*/\1/p' | head -1)
    DP=$(printf '%s' "$USAGE_JSON" | sed -n 's/.*"decimal_places": *\([0-9]*\).*/\1/p' | head -1)
    CUR=$(printf '%s' "$USAGE_JSON" | sed -n 's/.*"currency": *"\([A-Z]*\)".*/\1/p' | head -1)
    if [ -n "$USED" ]; then
      printf '{"ts":"%s","day":"%s","used":%s,"dp":%s,"cur":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%Y-%m-%d)" "$USED" "${DP:-2}" "${CUR:-EUR}" >> "$STORE"
    fi
  fi
  [ -z "$USAGE_ERR" ] || echo "conso: usage snapshot skipped: $USAGE_ERR" >&2
fi

# --- 2+3. ccusage over the recent days, merged into the cache ----------------------
TODAY=$(date +%Y-%m-%d)
SINCE=$(back "$HISTORY")
if [ -f "$CACHE" ] && grep -q '"schema": *1' "$CACHE" 2>/dev/null; then SINCE=$(back "$OVERLAP"); fi
OLD=/store/$(basename "$CACHE")
docker run --rm \
  -e SINCE_YMD="$SINCE" -e TODAY="$TODAY" -e HISTORY_DAYS="$HISTORY" -e OLD_CACHE="$OLD" \
  -e USAGE_JSON="$USAGE_JSON" -e USAGE_ERR="$USAGE_ERR" -e USAGE_SKIPPED=$((1 - API)) \
  -e NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -e CCUSAGE_VERSION="$VER" \
  -v "$PROJECTS":/root/.claude/projects:ro -v "$PK":/pk:ro -v "$DATA":/store:ro -v "$HERE":/m:ro \
  node:22-slim sh -c '
    /pk/node_modules/.bin/ccusage daily --json --breakdown --since "$(echo "$SINCE_YMD" | tr -d -)" \
      > /tmp/c.json 2>/tmp/c.err || { cat /tmp/c.err >&2; exit 1; }
    node /m/conso-merge.js /tmp/c.json' > "$TMP" \
  || { echo "conso: ccusage aggregation failed; cache left untouched" >&2; exit 1; }

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["schema"]==1 and isinstance(d["days"],dict)' "$TMP" \
  || { echo "conso: refresh produced an invalid cache; left untouched" >&2; exit 1; }
chmod 600 "$TMP"
mv "$TMP" "$CACHE"
say "conso: cache refreshed ($CACHE)"
