#!/usr/bin/env bash
# desktop.sh — where the Claude Desktop app keeps its files, per OS. One rule:
#   Windows  $APPDATA/Claude            (Git Bash exports APPDATA as a Windows
#                                        path: converted with cygpath when present)
#   Linux    ${XDG_CONFIG_HOME:-$HOME/.config}/Claude
#   macOS    ~/Library/Application Support/Claude
# PRW_DESKTOP_DIR overrides the whole directory (tests, unusual installs).
# bash 3.2 compatible. Sourced by prw (lib/*.sh) and by adapters/ccd/pr-relay.

claude_desktop_dir() {
  if [ -n "${PRW_DESKTOP_DIR:-}" ]; then
    printf '%s\n' "$PRW_DESKTOP_DIR"
  elif [ -n "${APPDATA:-}" ]; then
    printf '%s/Claude\n' "$(cygpath -u "$APPDATA" 2>/dev/null || printf '%s' "$APPDATA")"
  elif [ "$(uname -s)" = Linux ]; then
    printf '%s/Claude\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
  else
    printf '%s/Library/Application Support/Claude\n' "$HOME"
  fi
}
