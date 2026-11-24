#!/usr/bin/env bash
# list-secret-names.sh - show which variables an env-style file defines,
# WITHOUT ever printing a value.
#
# Output: <file>:<line>: <NAME> = <N chars>
# Only a complete assignment (NAME=value at the start of a line) produces
# output. Every other line prints nothing: continuation lines of a quoted
# multi-line value (a PEM key), lines without "=", base64 padding, YAML.
# So a file that prints nothing is "format not recognised", not "no secret".
#
# Runs itself in Docker (POSIX awk); nothing executed from the audited repo.
# Exit codes: 0 = done, 2 = usage error.
set -euo pipefail

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: list-secret-names.sh FILE [FILE ...]   (for example: .env .env.production config/*.env)" >&2
  exit 2
fi

# Run inside a container (see leads.sh): a .env symlinked to a file outside
# the current directory dangles there instead of being read.
if [ "${AUDIT_IN_DOCKER:-}" != 1 ]; then
  command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
  for a in "$@"; do
    case "$a" in /*) a2="$a" ;; *) a2="$PWD/$a" ;; esac
    case "$a2" in *"/../"*) echo "path with ..: $a" >&2; exit 2 ;; "$PWD"/*) ;; *) echo "run from the repository root; path outside it: $a" >&2; exit 2 ;; esac
  done
  exec docker run --rm --network none -e AUDIT_IN_DOCKER=1 -v "$PWD":"$PWD":ro -w "$PWD" \
    -v "$(cd "$(dirname "$0")" && pwd)":/skill-scripts:ro "${PYTHON_IMAGE:-python:3.12-slim}" \
    bash /skill-scripts/list-secret-names.sh "$@"
fi

for f in "$@"; do
  [ -f "$f" ] || { echo "skip (not a file): $f" >&2; continue; }
  awk '
    FNR == 1 { inq = 0 }
    inq { if (index($0, q)) inq = 0; next }
    /^(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=.*[^=]/ {
      i = index($0, "="); v = substr($0, i + 1)
      print FILENAME ":" FNR ": " substr($0, 1, i - 1) " = <" length(v) " chars>"
      c = substr(v, 1, 1)
      if ((c == "\"" || c == "\047") && index(substr(v, 2), c) == 0) { inq = 1; q = c }
    }' "$f"
done
