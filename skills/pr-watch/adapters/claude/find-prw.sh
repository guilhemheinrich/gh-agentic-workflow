#!/usr/bin/env bash
# find-prw.sh — sourced by the Claude hooks: set PRW to the prw executable,
# or return 1. Order: $PRW_BIN, the path baked in at install, $PATH, the
# usual skill locations, then the copy next to this adapter.
find_prw() {
  local here c
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "${PRW_BIN:-}" "@PRW@" "$(command -v prw 2>/dev/null)" \
    "$HOME/.agents/skills/pr-watch/scripts/prw" \
    "$HOME/.claude/skills/pr-watch/scripts/prw" \
    "$here/../../scripts/prw"; do
    [ -n "$c" ] && [ -f "$c" ] && { PRW="$c"; return 0; }
    # An explicit PRW_BIN that does not exist means "no prw": stop there.
    [ -n "${PRW_BIN:-}" ] && [ "$c" = "$PRW_BIN" ] && return 1
  done
  return 1
}
