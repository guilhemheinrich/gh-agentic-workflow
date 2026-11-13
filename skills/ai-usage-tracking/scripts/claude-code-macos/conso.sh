#!/bin/sh
# conso.sh - Claude Code consumption per period and per model. Instant: it only READS a precomputed cache.
#
# Usage: conso [-g day|week|month|session] [-d DAYS | -s DATE -u DATE] [-e EUR] [-n] [-S] [-j] [--refresh]
#   (default: last 7 days, per day, estimate + billed side by side; `conso -h` lists every flag)
#
# The slow work (Docker + ccusage + usage API) lives in conso-refresh.sh, run by the opt-in timer
# or by `conso --refresh`. This wrapper only locates its siblings (it may be a symlink) and calls
# the reader, which needs python3 (3.9+, standard library only).
set -eu
SELF=$0
[ -L "$SELF" ] && SELF=$(readlink "$SELF")
case "$SELF" in /*) ;; *) SELF=$(dirname "$0")/$SELF ;; esac
HERE=$(cd "$(dirname "$SELF")" && pwd)
command -v python3 >/dev/null 2>&1 || { echo "conso: python3 is required to read the cache" >&2; exit 1; }
exec python3 "$HERE/conso-report.py" "$@"
