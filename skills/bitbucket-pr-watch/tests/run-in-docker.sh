#!/usr/bin/env bash
# run-in-docker.sh — run the bbw test files in a throwaway bash 3.2 container.
#
#   bash tests/run-in-docker.sh               # every tests/*.test.sh
#   bash tests/run-in-docker.sh wait.test.sh  # one file
#
# bash 3.2 is the macOS system bash: passing here proves the scripts run on a
# stock Mac. The image carries only what bbw may use: bash, jq, git, coreutils.
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
only="${1:-}"
exec docker run --rm -v "$SKILL_DIR:/skill:ro" -e ONLY="$only" bash:3.2 sh -c '
  apk add --no-cache -q jq git curl coreutils >/dev/null || exit 1
  rc=0
  for t in /skill/tests/*.test.sh; do
    [ -n "$ONLY" ] && [ "$(basename "$t")" != "$ONLY" ] && continue
    echo "== $(basename "$t")"
    bash "$t" || rc=1
  done
  exit $rc'
