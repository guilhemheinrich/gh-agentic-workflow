#!/usr/bin/env bash
# own-writes-hook.sh — Claude Code PostToolUse hook for the Linear writes the
# agent makes through the Linear MCP. Matcher (a regex: the server name carries
# a UUID prefix in Claude Desktop, `claude_ai_Linear` in the CLI):
#   mcp__.*__(save_comment|save_issue)
#
# The agent and the human share one Linear account, and a comment posted
# through the MCP has no botActor, so a comment cannot be told apart by author.
# This hook records the created comment id, or the issue identifier and its new
# state, in lw's own_writes table, so a pilot is never woken by the writes of
# its own child sessions. Parsing and validation live in `lw own-write --hook`
# (another MCP's save_comment and failed calls write nothing).
#
# Finds lw from $LW_BIN, else ../../scripts/lw next to this file. Silent, exit 0
# always. LW_HOOKS=0 disables it. Installed by `lw setup --claude` (LW-8).
set -u
[ "${LW_HOOKS:-1}" = 1 ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here=.
lw="${LW_BIN:-$here/../../scripts/lw}"
[ -f "$lw" ] || exit 0

python3 "$lw" own-write --hook >/dev/null 2>&1
exit 0
