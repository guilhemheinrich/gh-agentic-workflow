#!/usr/bin/env bash
# app-dir.test.sh — session-title.sh finds the desktop app's session files on
# every OS. The OS is simulated with a fake `uname` and `cygpath` on PATH and
# the HOME / XDG_CONFIG_HOME / APPDATA variables; nothing outside a temp dir is read.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/session-title.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${3:-}" ] && printf '       %s\n' "$3"; fi; }

mkdir -p "$WORK/bin"
REAL_UNAME="$(command -v uname)"
cat >"$WORK/bin/uname" <<SH
#!/bin/sh
if [ "\$1" = "-s" ] && [ -n "\${FAKE_UNAME:-}" ]; then echo "\$FAKE_UNAME"; else exec "$REAL_UNAME" "\$@"; fi
SH
# Git Bash cygpath -u: C:\Users\x -> /c/Users/x
cat >"$WORK/bin/cygpath" <<'SH'
#!/bin/sh
[ "$1" = "-u" ] || exit 1
printf '%s\n' "$2" | sed -e 's|^\([A-Za-z]\):|/\L\1|' -e 's|\\|/|g'
SH
chmod +x "$WORK/bin/uname" "$WORK/bin/cygpath"

# seed DIR — one live session file the snapshot must list.
seed() {
  mkdir -p "$1/org/acct"
  printf '{"sessionId":"local_t1","title":"🟠 ✅ Closed · test","cwd":"/x","branch":"b","isArchived":false,"lastActivityAt":%s}\n' "$(( $(date +%s) * 1000 ))" >"$1/org/acct/local_t1.json"
}
# snap — run snapshot with a clean environment plus the given VAR=value pairs.
snap() { env -i PATH="$WORK/bin:$PATH" HOME="$WORK/home" "$@" bash "$SCRIPT" snapshot --days 2 2>&1; }
mkdir -p "$WORK/home"

# macOS
seed "$WORK/home/Library/Application Support/Claude/claude-code-sessions"
out="$(snap FAKE_UNAME=Darwin)"
check "macOS: ~/Library/Application Support/Claude" '[ "$(jq -r ".[0].sessionId" <<<"$out")" = local_t1 ]' "$out"

# Linux, default XDG dir
seed "$WORK/home/.config/Claude/claude-code-sessions"
out="$(snap FAKE_UNAME=Linux)"
check "Linux: ~/.config/Claude" '[ "$(jq -r ".[0].sessionId" <<<"$out")" = local_t1 ]' "$out"
rm -rf "$WORK/home/Library"
out="$(snap FAKE_UNAME=Darwin)"
check "macOS dir absent: empty, not an error" '[ "$out" = "[]" ]' "$out"

# Linux, custom XDG_CONFIG_HOME wins over ~/.config
rm -rf "$WORK/home/.config"
seed "$WORK/xdg/Claude/claude-code-sessions"
out="$(snap FAKE_UNAME=Linux XDG_CONFIG_HOME="$WORK/xdg")"
check "Linux: XDG_CONFIG_HOME honoured" '[ "$(jq -r ".[0].sessionId" <<<"$out")" = local_t1 ]' "$out"

# Windows (Git Bash): APPDATA is a Windows path, cygpath makes it POSIX.
# /c/... cannot exist here, so the fake cygpath maps onto the temp dir.
cat >"$WORK/bin/cygpath" <<SH
#!/bin/sh
[ "\$1" = "-u" ] || exit 1
printf '%s\n' "$WORK/win/AppData/Roaming"
SH
seed "$WORK/win/AppData/Roaming/Claude/claude-code-sessions"
out="$(snap FAKE_UNAME=MINGW64_NT-10.0 APPDATA='C:\Users\x\AppData\Roaming')"
check "Windows: \$APPDATA/Claude via cygpath" '[ "$(jq -r ".[0].sessionId" <<<"$out")" = local_t1 ]' "$out"

# Override beats everything.
seed "$WORK/override"
out="$(snap FAKE_UNAME=Linux APPDATA=nope SESSION_TITLE_APP_DIR="$WORK/override")"
check "SESSION_TITLE_APP_DIR overrides the OS rule" '[ "$(jq -r ".[0].sessionId" <<<"$out")" = local_t1 ]' "$out"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
