#!/usr/bin/env bash
# desktop.test.sh — claude_desktop_dir picks the Claude Desktop directory per
# OS, and the two consumers (plan_bitbucket_mcp, pr-relay) follow it.
. "$(dirname "$0")/lib.sh"

mkdir -p "$WORK/fakebin"
REAL_UNAME="$(command -v uname)"
printf '#!/bin/sh\nif [ "$1" = "-s" ] && [ -n "${FAKE_UNAME:-}" ]; then echo "$FAKE_UNAME"; else exec "%s" "$@"; fi\n' "$REAL_UNAME" >"$WORK/fakebin/uname"
printf '#!/bin/sh\n[ "$1" = "-u" ] || exit 1\necho "%s/win/Roaming"\n' "$WORK" >"$WORK/fakebin/cygpath"
chmod +x "$WORK/fakebin/uname" "$WORK/fakebin/cygpath"
export PATH="$WORK/fakebin:$PATH"
unset APPDATA PRW_DESKTOP_DIR

dir() { ( . "$SKILL_DIR/scripts/lib/desktop.sh"; claude_desktop_dir ); }

out="$(FAKE_UNAME=Darwin dir)"
check "macOS: Library/Application Support/Claude" '[ "$out" = "$HOME/Library/Application Support/Claude" ]' "$out"
out="$(FAKE_UNAME=Linux dir)"
check "Linux: XDG_CONFIG_HOME/Claude" '[ "$out" = "$XDG_CONFIG_HOME/Claude" ]' "$out"
out="$(unset XDG_CONFIG_HOME; FAKE_UNAME=Linux dir)"
check "Linux without XDG_CONFIG_HOME: ~/.config/Claude" '[ "$out" = "$HOME/.config/Claude" ]' "$out"
out="$(FAKE_UNAME=MINGW64_NT APPDATA='C:\Users\x\AppData\Roaming' dir)"
check "Windows: APPDATA converted by cygpath" '[ "$out" = "$WORK/win/Roaming/Claude" ]' "$out"
out="$(FAKE_UNAME=Linux PRW_DESKTOP_DIR=/custom dir)"
check "PRW_DESKTOP_DIR overrides" '[ "$out" = /custom ]' "$out"

# plan_bitbucket_mcp reads the desktop config of the current OS.
mkdir -p "$XDG_CONFIG_HOME/Claude"
printf '{"mcpServers":{"bitbucket":{}}}' >"$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
out="$(FAKE_UNAME=Linux CLAUDE_SETTINGS="$WORK/none.json" bash -c ". '$SKILL_DIR/scripts/lib/desktop.sh'; . '$SKILL_DIR/scripts/lib/claude.sh'; . '$SKILL_DIR/scripts/lib/plan.sh'; plan_bitbucket_mcp")"
check "plan finds the Bitbucket MCP in the Linux desktop config" '[ "$out" = "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json" ]' "$out"

# pr-relay (reached through a symlink, as installed) defaults its sessions dir
# to <desktop dir>/claude-code-sessions: `scan` on an empty store prints no delivery.
mkdir -p "$XDG_CONFIG_HOME/Claude/claude-code-sessions/o/a" "$WORK/links"
ln -s "$SKILL_DIR/adapters/ccd/pr-relay" "$WORK/links/pr-relay"
printf '{"cliSessionId":"c1","sessionId":"local_x","title":"t"}' >"$XDG_CONFIG_HOME/Claude/claude-code-sessions/o/a/local_x.json"
out="$(FAKE_UNAME=Linux PR_RELAY_STATE_DIR="$WORK/relay-state" "$WORK/links/pr-relay" scan 2>&1)"; rc=$?
check "pr-relay sources desktop.sh through a symlink and scans" '[ "$rc" = 0 ] && jq -e . >/dev/null <<<"$out"' "rc=$rc $out"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
