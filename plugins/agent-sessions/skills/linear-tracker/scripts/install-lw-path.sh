#!/bin/sh
# install-lw-path.sh - put `lw` on the PATH of bash, zsh and fish (idempotent).
#
# Usage: sh install-lw-path.sh [--uninstall]
#
# What it does (safe to re-run):
#   1. Symlinks the `lw` that sits next to this installer as ~/.local/bin/lw
#      (lw resolves the link to find its hooks and template).
#   2. Makes sure ~/.local/bin is on PATH, once per shell:
#      - ~/.zshrc and ~/.bashrc (when they exist): a marker block
#        `# >>> lw >>>` ... `# <<< lw <<<`, stripped then re-appended - but only
#        when the file has no other ~/.local/bin PATH guard (the conso block
#        already adds one: it is reused, never duplicated);
#      - fish: its own ~/.config/fish/conf.d/lw-path.fish, only when no other
#        conf.d file already mentions ~/.local/bin.
#   --uninstall removes the link, our blocks and our fish file; a guard that
#   belongs to another tool is left alone.
#
# Refuses to run from a git checkout or worktree (the link would outlive it):
# run it from the installed copy, ~/.agents/skills/linear-tracker/scripts/.
# LW_ALLOW_CHECKOUT=1 overrides, for tests only.
# Overridable for testing: HOME.
set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
LW_BIN="$SRC_DIR/lw"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/lw"
MARK_START="# >>> lw >>>"
MARK_END="# <<< lw <<<"
FISH_DIR="$HOME/.config/fish/conf.d"
FISH_FILE="$FISH_DIR/lw-path.fish"

strip_block() { # $1 = rc file
  [ -f "$1" ] || return 0
  sed "/^$MARK_START\$/,/^$MARK_END\$/d" "$1" > "$1.lw.tmp" && mv "$1.lw.tmp" "$1"
}

# Does $1 (rc file, our block already stripped) carry a ~/.local/bin PATH guard?
has_guard() { grep -q '\.local/bin' "$1"; }

UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$UNINSTALL" = 1 ]; then
  [ -L "$LINK" ] && rm -f "$LINK"
  rm -f "$FISH_FILE"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do strip_block "$rc"; done
  echo "lw removed from PATH (the skill, its daemon and its hooks are untouched)."
  exit 0
fi

[ -f "$LW_BIN" ] || { echo "lw not found next to the installer ($SRC_DIR)" >&2; exit 1; }
if [ "${LW_ALLOW_CHECKOUT:-}" != "1" ]; then
  case "$SRC_DIR" in
    */worktrees/*) in_checkout=1 ;;
    *) in_checkout=0; d=$SRC_DIR
       while [ "$d" != "/" ]; do [ -e "$d/.git" ] && in_checkout=1 && break; d=$(dirname "$d"); done ;;
  esac
  if [ "$in_checkout" = 1 ]; then
    echo "refusing: running from a git checkout ($SRC_DIR); install the skills first (bash install.sh) and run the copy under ~/.agents/skills/" >&2
    exit 1
  fi
fi

# 1. The link. A regular file named lw is somebody else's: never overwrite it.
mkdir -p "$BIN_DIR"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "refusing: $LINK exists and is not a symlink" >&2
  exit 1
fi
ln -sf "$LW_BIN" "$LINK"

# 2. PATH guard, one per rc file.
block() {
  printf '%s\n' "$MARK_START"
  printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  printf '%s\n' "$MARK_END"
}
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$rc" ] || continue
  strip_block "$rc"
  if has_guard "$rc"; then
    echo "  $rc: ~/.local/bin guard already present, left as is"
  else
    { printf '\n'; block; } >> "$rc"
    echo "  updated $rc"
  fi
done

if command -v fish >/dev/null 2>&1 || [ -d "$HOME/.config/fish" ]; then
  mkdir -p "$FISH_DIR"
  rm -f "$FISH_FILE"
  if grep -qs '\.local/bin' "$FISH_DIR"/*.fish 2>/dev/null; then
    echo "  fish: ~/.local/bin guard already present in conf.d, none added"
  else
    cat > "$FISH_FILE" <<'FISH'
# lw - managed by install-lw-path.sh (do not edit; re-run the installer instead).
fish_add_path -g "$HOME/.local/bin"
FISH
    echo "  wrote $FISH_FILE"
  fi
fi

echo "lw linked -> $LINK ($LW_BIN)"
echo "Open a new terminal, then try: lw doctor"
