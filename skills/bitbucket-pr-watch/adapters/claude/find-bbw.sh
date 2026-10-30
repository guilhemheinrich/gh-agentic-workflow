#!/usr/bin/env bash
# find-bbw.sh — sourced by the Claude hooks: set BBW to the bbw executable,
# or return 1. Order: $BBW_BIN, the path baked in at install, $PATH, the
# usual skill locations, then the copy next to this adapter.
find_bbw() {
  local here c
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "${BBW_BIN:-}" "@BBW@" "$(command -v bbw 2>/dev/null)" \
    "$HOME/.agents/skills/bitbucket-pr-watch/scripts/bbw" \
    "$HOME/.claude/skills/bitbucket-pr-watch/scripts/bbw" \
    "$here/../../scripts/bbw"; do
    [ -n "$c" ] && [ -f "$c" ] && { BBW="$c"; return 0; }
    # An explicit BBW_BIN that does not exist means "no bbw": stop there.
    [ -n "${BBW_BIN:-}" ] && [ "$c" = "$BBW_BIN" ] && return 1
  done
  return 1
}
