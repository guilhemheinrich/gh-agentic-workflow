#!/usr/bin/env bash
# stage-inputs.sh - copy named lockfiles/manifests of the audited checkout
# into $OUT/inputs, so an ecosystem tool (npm audit, pip-audit, cargo audit)
# runs on copies and never with the repository as working directory.
#
# Why not `-v "$PWD/requirements.txt":/in/...`: Docker resolves a bind source
# on the host, so a requirements.txt symlinked to ~/.aws/credentials is
# handed to the container; a missing source makes Docker create a directory
# in the checkout. Here the checkout is mounted read-only as a whole, and only
# regular files that are not symlinks and resolve inside it are copied.
#
# Usage (from the repository root): stage-inputs.sh --out DIR FILE [FILE ...]
#   FILE is relative to the repository root (package-lock.json, api/Cargo.lock)
# Output: DIR/inputs/<basename>, and one line per file: "staged: F" or
#   "INCOMPLETE: not scanned: F (<reason>)".
# Exit codes: 0 = every file staged, 2 = at least one not staged, or error.
set -euo pipefail

OUT="${SECURITY_AUDIT_OUT:-}"
if [ "${1:-}" = "--out" ]; then OUT="$2"; shift 2; fi
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: stage-inputs.sh --out DIR FILE [FILE ...]   (run from the repository root)" >&2
  exit 2
fi
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
. "$(dirname "$0")/out-guard.sh"
check_out_dir "$PWD"
for f in "$@"; do
  case "$f" in /*|..|../*|*/../*|*/..) echo "relative path inside the repository only: $f" >&2; exit 2 ;; esac
done
[ ! -L "$OUT/inputs" ] || { echo "$OUT/inputs is a symlink, refused" >&2; exit 2; }
mkdir -p "$OUT/inputs"

docker run --rm --network none -v "$PWD":/src:ro -v "$OUT/inputs":/stage \
  "${PYTHON_IMAGE:-python:3.12-slim}" sh -c '
  rc=0
  for f in "$@"; do
    p="/src/$f"
    if [ -L "$p" ]; then why="symlink"
    elif [ ! -e "$p" ]; then why="missing"
    elif [ ! -f "$p" ]; then why="not a regular file"
    else
      case "$(realpath "$p")" in /src/*) why="" ;; *) why="resolves outside the checkout" ;; esac
    fi
    b="$(basename "$f")"
    if [ -z "$why" ] && [ ! -e "/stage/$b" ]; then cp -- "$p" "/stage/$b"; echo "staged: $f"
    else [ -n "$why" ] || why="another file named $b is already staged"
      echo "INCOMPLETE: not scanned: $f ($why)" >&2; rc=2; fi
  done
  exit $rc' sh "$@"
