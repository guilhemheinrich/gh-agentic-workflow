#!/bin/sh
# test-setup-sandbox.sh - sandbox test of setup-conso.sh (fake HOME, stubbed launchctl).
#
# Run from the repo root, in Docker (nothing touches the real HOME):
#   docker run --rm -v "$PWD/skills/ai-usage-tracking/scripts/claude-code-macos":/t:ro alpine:3.20 sh /t/test-setup-sandbox.sh
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
check "installed script identical to the skill source" cmp -s "$HERE/conso.sh" "$HOME/.config/conso/conso.sh"
check "fish file written" test -f "$HOME/.config/fish/conf.d/conso.fish"
check "no timer without --with-timer" test ! -e "$PLIST"
check "launchctl not called without --with-timer" test ! -e "$HOME/launchctl.calls"

sh "$HERE/setup-conso.sh" --with-timer >/dev/null
sh "$HERE/setup-conso.sh" --with-timer >/dev/null
check "plist written" test -f "$PLIST"
check "plist has no unresolved placeholder" test "$(grep -c '__' "$PLIST")" = 0
check "plist runs conso -S" grep -q '<string>-S</string>' "$PLIST"
check "plist StartInterval 3600" grep -q '<integer>3600</integer>' "$PLIST"
check "plist RunAtLoad" grep -q '<key>RunAtLoad</key>' "$PLIST"
check "launchctl load went through the stub" grep -q "^load $PLIST" "$HOME/launchctl.calls"
for rc in .zshrc .bashrc; do
  check "still one marker block in $rc" test "$(count_blocks "$HOME/$rc")" = 1
done

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
