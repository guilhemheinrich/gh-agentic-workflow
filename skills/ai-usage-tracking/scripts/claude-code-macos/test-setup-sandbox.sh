#!/bin/sh
# test-setup-sandbox.sh - sandbox test of setup-conso.sh (fake HOME, stubbed launchctl).
#
# Run from the repo root, in Docker (nothing touches the real HOME):
#   docker run --rm -v "$PWD/skills/ai-usage-tracking/scripts/claude-code-macos":/t:ro alpine:3.20 sh /t/test-setup-sandbox.sh
# (conso-report.py needs python3 and is tested by test-conso-report.py, see its header.)
# Or directly (still sandboxed by a temp HOME): sh test-setup-sandbox.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d)
unset CONSO_DIR
trap 'rm -rf "$HOME"' EXIT
FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { # $1 = label, rest = test command
  label=$1; shift
  if "$@"; then ok "$label"; else fail "$label"; fi
}
count_blocks() { grep -c '^# >>> conso >>>$' "$1" || true; }

# Stub launchctl: record calls, do nothing else.
STUB="$HOME/launchctl-stub"
printf '#!/bin/sh\necho "$@" >> "%s/launchctl.calls"\n' "$HOME" > "$STUB"
chmod +x "$STUB"
export LAUNCHCTL="$STUB"

printf 'export FOO=1\n' > "$HOME/.zshrc"
printf 'export BAR=1\n' > "$HOME/.bashrc"
mkdir -p "$HOME/.config/fish"
PLIST="$HOME/Library/LaunchAgents/com.gh-agentic.conso-snapshot.plist"

sh "$HERE/setup-conso.sh" >/dev/null
sh "$HERE/setup-conso.sh" >/dev/null
for rc in .zshrc .bashrc; do
  check "exactly one marker block in $rc after 2 runs" test "$(count_blocks "$HOME/$rc")" = 1
done
check "rc content preserved" grep -q 'FOO=1' "$HOME/.zshrc"
check "symlink ~/.local/bin/conso" test -L "$HOME/.local/bin/conso"
check "symlink resolves to the copied script" test -x "$HOME/.config/conso/conso.sh"
for f in conso.sh conso-report.py conso-refresh.sh conso-merge.js; do
  check "installed $f identical to the skill source" cmp -s "$HERE/$f" "$HOME/.config/conso/$f"
done
check "installed scripts executable" test -x "$HOME/.config/conso/conso-refresh.sh" -a -x "$HOME/.config/conso/conso-report.py"
check "no interval file without --with-timer" test ! -e "$HOME/.config/conso/interval"
check "fish file written" test -f "$HOME/.config/fish/conf.d/conso.fish"
check "no timer without --with-timer" test ! -e "$PLIST"
check "launchctl not called without --with-timer" test ! -e "$HOME/launchctl.calls"

sh "$HERE/setup-conso.sh" --with-timer >/dev/null
sh "$HERE/setup-conso.sh" --with-timer >/dev/null
check "plist written" test -f "$PLIST"
check "plist has no unresolved placeholder" test "$(grep -c '__' "$PLIST")" = 0
check "plist runs conso -S" grep -q '<string>-S</string>' "$PLIST"
check "default interval: plist StartInterval 600 (10 min)" grep -q '<integer>600</integer>' "$PLIST"
check "interval file records 600 (staleness = 3x)" test "$(cat "$HOME/.config/conso/interval")" = 600
check "plist RunAtLoad" grep -q '<key>RunAtLoad</key>' "$PLIST"
check "launchctl load went through the stub" grep -q "^load $PLIST" "$HOME/launchctl.calls"
for rc in .zshrc .bashrc; do
  check "still one marker block in $rc" test "$(count_blocks "$HOME/$rc")" = 1
done

# Interval: re-running with a new --interval rewrites the plist and reloads it via launchctl.
loads_before=$(grep -c "^load $PLIST" "$HOME/launchctl.calls")
sh "$HERE/setup-conso.sh" --with-timer --interval 12h >/dev/null
check "--interval 12h renders 43200" grep -q '<integer>43200</integer>' "$PLIST"
check "old default no longer in plist" test "$(grep -c '<integer>600</integer>' "$PLIST")" = 0
check "interval file follows --interval" test "$(cat "$HOME/.config/conso/interval")" = 43200
check "RunAtLoad kept with custom interval" grep -q '<key>RunAtLoad</key>' "$PLIST"
check "re-run with new interval reloaded the agent" test "$(grep -c "^load $PLIST" "$HOME/launchctl.calls")" = $((loads_before + 1))
sh "$HERE/setup-conso.sh" --with-timer --interval 90m >/dev/null
check "--interval 90m renders 5400" grep -q '<integer>5400</integer>' "$PLIST"
sh "$HERE/setup-conso.sh" --with-timer --interval=3600 >/dev/null
check "--interval=3600 (bare seconds) renders 3600" grep -q '<integer>3600</integer>' "$PLIST"
sh "$HERE/setup-conso.sh" --with-timer --interval 1d >/dev/null
check "--interval 1d renders 86400" grep -q '<integer>86400</integer>' "$PLIST"
sh "$HERE/setup-conso.sh" --with-timer --interval 60 >/dev/null
check "--interval 60 (minimum) accepted" grep -q '<integer>60</integer>' "$PLIST"

# Invalid values: exit non-zero, plist untouched, launchctl not called again.
calls_before=$(wc -l < "$HOME/launchctl.calls")
plist_before=$(cat "$PLIST")
for bad in abc 12x 0 0h -5 -1h 1.5h 59 59s 1m5s ""; do
  if sh "$HERE/setup-conso.sh" --with-timer --interval "$bad" >/dev/null 2>&1; then
    fail "invalid --interval '$bad' rejected"
  else
    ok "invalid --interval '$bad' rejected"
  fi
done
if sh "$HERE/setup-conso.sh" --with-timer --interval >/dev/null 2>&1; then
  fail "--interval without a value rejected"
else ok "--interval without a value rejected"; fi
if sh "$HERE/setup-conso.sh" --interval 12h >/dev/null 2>&1; then
  fail "--interval without --with-timer rejected"
else ok "--interval without --with-timer rejected"; fi
check "rejections left the plist untouched" test "$(cat "$PLIST")" = "$plist_before"
check "rejections did not call launchctl" test "$(wc -l < "$HOME/launchctl.calls")" = "$calls_before"

sh "$HERE/setup-conso.sh" --uninstall >/dev/null
check "uninstall: launchctl unload went through the stub" grep -q "^unload $PLIST" "$HOME/launchctl.calls"
check "uninstall: plist gone" test ! -e "$PLIST"
check "uninstall: symlink gone" test ! -e "$HOME/.local/bin/conso" -a ! -L "$HOME/.local/bin/conso"
check "uninstall: fish file gone" test ! -e "$HOME/.config/fish/conf.d/conso.fish"
check "uninstall: conso dir gone" test ! -e "$HOME/.config/conso"
for rc in .zshrc .bashrc; do
  check "uninstall: no marker left in $rc" test "$(count_blocks "$HOME/$rc")" = 0
done
check "uninstall: user rc content kept" grep -q 'BAR=1' "$HOME/.bashrc"

if [ "$FAILS" = 0 ]; then echo "ALL PASSED"; else echo "$FAILS FAILED"; exit 1; fi
