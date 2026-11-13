#!/bin/sh
# setup-conso.sh - idempotent installer for the `conso` command (Claude Code usage report, macOS).
#
# Usage: sh setup-conso.sh [--with-timer [--interval <duration>]] [--uninstall]
#
# What it does (safe to re-run):
#   1. Copies conso.sh, conso-report.py, conso-refresh.sh and conso-merge.js (next to this installer:
#      single source of truth) to $CONSO_DIR (default ~/.config/conso).
#   2. Symlinks it as ~/.local/bin/conso.
#   3. Maintains a marker block (# >>> conso >>> ... # <<< conso <<<) in ~/.zshrc and
#      ~/.bashrc (stripped then re-appended, so it survives rewrites by other managers)
#      and its own file ~/.config/fish/conf.d/conso.fish.
#   4. --with-timer (opt-in, never implied): installs the launchd agent
#      ~/Library/LaunchAgents/com.gh-agentic.conso-snapshot.plist running `conso -S`
#      (= silent cache refresh: ccusage aggregation + usage snapshot) every --interval (default 10 min;
#      StartInterval in seconds, RunAtLoad). The interval is also written to $CONSO_DIR/interval so
#      `conso` knows when its cache is stale (3x the interval). Re-run with a new --interval to change it (plist rewritten, reloaded).
#      --interval <duration>: seconds, or a number + s|m|h|d (3600, 90m, 12h, 1d). Minimum 60s.
#      Invalid/non-positive/<60s values, and --interval without --with-timer, exit 1.
#   --uninstall removes everything above, including the timer if present.
#
# Overridable for testing: HOME, CONSO_DIR, LAUNCHCTL (launchctl binary or stub).
set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONSO_DIR="${CONSO_DIR:-$HOME/.config/conso}"
BIN_DIR="$HOME/.local/bin"
MARK_START="# >>> conso >>>"
MARK_END="# <<< conso <<<"
FISH_FILE="$HOME/.config/fish/conf.d/conso.fish"
LABEL="com.gh-agentic.conso-snapshot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"

strip_block() { # $1 = rc file
  [ -f "$1" ] || return 0
  sed "/^$MARK_START\$/,/^$MARK_END\$/d" "$1" > "$1.conso.tmp" && mv "$1.conso.tmp" "$1"
}

# parse_duration <value>: prints seconds (integer >= 60) or exits 1 with a clear error.
parse_duration() {
  v=$1
  num=${v%[smhd]}
  unit=${v#"$num"}
  case "$num" in
    ''|*[!0-9]*) echo "invalid --interval '$v': expected seconds or a number with unit s|m|h|d (e.g. 3600, 90m, 12h)" >&2; exit 1 ;;
  esac
  [ ${#num} -le 9 ] || { echo "invalid --interval '$v': number too large" >&2; exit 1; }
  num=$(printf '%s' "$num" | sed 's/^0*//')
  num=${num:-0}
  case "$unit" in
    ''|s) mult=1 ;;
    m) mult=60 ;;
    h) mult=3600 ;;
    d) mult=86400 ;;
  esac
  secs=$((num * mult))
  [ "$secs" -gt 0 ] || { echo "invalid --interval '$v': must be positive" >&2; exit 1; }
  [ "$secs" -ge 60 ] || { echo "invalid --interval '$v': below the 60 s minimum" >&2; exit 1; }
  printf '%s' "$secs"
}

WITH_TIMER=0
UNINSTALL=0
INTERVAL_RAW=""
INTERVAL_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-timer) WITH_TIMER=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --interval)
      [ $# -ge 2 ] || { echo "--interval requires a value (e.g. 12h)" >&2; exit 1; }
      INTERVAL_RAW=$2; INTERVAL_SET=1; shift ;;
    --interval=*) INTERVAL_RAW=${1#--interval=}; INTERVAL_SET=1 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

INTERVAL_SECS=600
if [ "$INTERVAL_SET" = 1 ]; then
  [ "$WITH_TIMER" = 1 ] && [ "$UNINSTALL" = 0 ] || { echo "--interval only applies together with --with-timer" >&2; exit 1; }
  INTERVAL_SECS=$(parse_duration "$INTERVAL_RAW") || exit 1
fi

if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$PLIST" ]; then
    "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
  fi
  rm -f "$BIN_DIR/conso" "$FISH_FILE"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do strip_block "$rc"; done
  rm -rf "$CONSO_DIR"
  echo "conso removed (snapshots, cache and pinned ccusage in ~/.local/share/conso are kept)."
  exit 0
fi

FILES="conso.sh conso-report.py conso-refresh.sh conso-merge.js"
for f in $FILES; do
  [ -f "$SRC_DIR/$f" ] || { echo "$f not found next to the installer ($SRC_DIR)" >&2; exit 1; }
done
mkdir -p "$CONSO_DIR" "$BIN_DIR"

# 1. The script itself (copied, never embedded).
for f in $FILES; do cp "$SRC_DIR/$f" "$CONSO_DIR/$f"; done
chmod +x "$CONSO_DIR/conso.sh" "$CONSO_DIR/conso-report.py" "$CONSO_DIR/conso-refresh.sh"

# 2. PATH entry.
ln -sf "$CONSO_DIR/conso.sh" "$BIN_DIR/conso"

# 3. Shell integration.
block() {
  printf '%s\n' "$MARK_START"
  printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  printf '%s\n' "$MARK_END"
}
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$rc" ] || continue
  strip_block "$rc"
  { printf '\n'; block; } >> "$rc"
  echo "  updated $rc"
done

if command -v fish >/dev/null 2>&1 || [ -d "$HOME/.config/fish" ]; then
  mkdir -p "$(dirname "$FISH_FILE")"
  cat > "$FISH_FILE" <<'FISH'
# conso - managed by setup-conso.sh (do not edit; re-run the installer instead).
fish_add_path -g "$HOME/.local/bin"
FISH
  echo "  wrote $FISH_FILE"
fi

# 4. Opt-in snapshot timer (default 10 min; re-running reloads it with the new interval).
if [ "$WITH_TIMER" = 1 ]; then
  mkdir -p "$(dirname "$PLIST")" "$HOME/.local/share/conso"
  sed -e "s|__CONSO_BIN__|$BIN_DIR/conso|g" -e "s|__HOME__|$HOME|g" -e "s|__INTERVAL__|$INTERVAL_SECS|g" \
    "$SRC_DIR/com.gh-agentic.conso-snapshot.plist.template" > "$PLIST"
  "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
  "$LAUNCHCTL" load "$PLIST"
  printf '%s\n' "$INTERVAL_SECS" > "$CONSO_DIR/interval"
  echo "  timer installed: $PLIST (conso -S every ${INTERVAL_SECS}s)"
fi

"$BIN_DIR/conso" -h >/dev/null 2>&1 || true
echo "conso installed -> $BIN_DIR/conso (script: $CONSO_DIR/conso.sh)"
echo "Open a new terminal, then try: conso   |   conso -g week -d 30"
