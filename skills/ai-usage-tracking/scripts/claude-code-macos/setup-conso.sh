#!/bin/sh
# setup-conso.sh - idempotent installer for the `conso` command (Claude Code usage report, macOS).
#
# Usage: sh setup-conso.sh [--with-timer] [--uninstall]
#
# What it does (safe to re-run):
#   1. Copies conso.sh (next to this installer: single source of truth) to
#      $CONSO_DIR/conso.sh (default ~/.config/conso).
#   2. Symlinks it as ~/.local/bin/conso.
#   3. Maintains a marker block (# >>> conso >>> ... # <<< conso <<<) in ~/.zshrc and
#      ~/.bashrc (stripped then re-appended, so it survives rewrites by other managers)
#      and its own file ~/.config/fish/conf.d/conso.fish.
#   4. --with-timer (opt-in, never implied): installs the launchd agent
#      ~/Library/LaunchAgents/com.gh-agentic.conso-snapshot.plist running `conso -S`
#      hourly (StartInterval 3600, RunAtLoad), so out-of-plan snapshots accumulate.
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

WITH_TIMER=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --with-timer) WITH_TIMER=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$PLIST" ]; then
    "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
  fi
  rm -f "$BIN_DIR/conso" "$FISH_FILE"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do strip_block "$rc"; done
  rm -rf "$CONSO_DIR"
  echo "conso removed (snapshots in ~/.local/share/conso are kept)."
  exit 0
fi

[ -f "$SRC_DIR/conso.sh" ] || { echo "conso.sh not found next to the installer ($SRC_DIR)" >&2; exit 1; }
mkdir -p "$CONSO_DIR" "$BIN_DIR"

# 1. The script itself (copied, never embedded).
cp "$SRC_DIR/conso.sh" "$CONSO_DIR/conso.sh"
chmod +x "$CONSO_DIR/conso.sh"

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

# 4. Opt-in hourly snapshot timer.
if [ "$WITH_TIMER" = 1 ]; then
  mkdir -p "$(dirname "$PLIST")" "$HOME/.local/share/conso"
  sed -e "s|__CONSO_BIN__|$BIN_DIR/conso|g" -e "s|__HOME__|$HOME|g" \
    "$SRC_DIR/com.gh-agentic.conso-snapshot.plist.template" > "$PLIST"
  "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
  "$LAUNCHCTL" load "$PLIST"
  echo "  timer installed: $PLIST (hourly conso -S)"
fi

"$BIN_DIR/conso" -h >/dev/null 2>&1 || true
echo "conso installed -> $BIN_DIR/conso (script: $CONSO_DIR/conso.sh)"
echo "Open a new terminal, then try: conso   |   conso -g week -d 30"
