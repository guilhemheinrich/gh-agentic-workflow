#!/usr/bin/env bash
# lib.sh — shared helpers for the bbw test files. Source it, never run it.
#
# Every test runs with a state dir and a HOME whose paths contain spaces: the
# Tiger Bus watcher once lost two events to word splitting on such a path.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BBW="$SKILL_DIR/scripts/bbw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home dir"
export BBW_STATE_DIR="$WORK/state dir with spaces"
export XDG_CONFIG_HOME="$HOME/.config"
export BBW_API_BASE="http://fake.test/2.0"
export BITBUCKET_WATCH_USER="dev@example.test"
export BITBUCKET_WATCH_TOKEN="tok-SECRET-123"
mkdir -p "$HOME"
PASS=0 FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
nok() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
check() { if eval "$2"; then ok "$1"; else nok "$1" "${3:-}"; fi; }

# use_fixture DIR — serve fixture files through the fake curl.
# DIR holds <key>.json bodies, optional <key>.code (HTTP code) and
# <key>.headers. The key is the URL after $BBW_API_BASE/ with every character
# outside [A-Za-z0-9._-] replaced by "_".
use_fixture() {
  mkdir -p "$WORK/bin"
  cp "$SKILL_DIR/tests/fake-curl" "$WORK/bin/curl"
  chmod +x "$WORK/bin/curl"
  export PATH="$WORK/bin:$PATH"
  export FAKE_CURL_DIR="$1"
  : >"$WORK/requests.log"
  export FAKE_CURL_LOG="$WORK/requests.log"
}

# fixture_key URL_TAIL — the file stem the fake curl looks for.
fixture_key() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'; }

summary() {
  printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
