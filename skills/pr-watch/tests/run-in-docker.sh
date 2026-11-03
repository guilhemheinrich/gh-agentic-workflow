#!/usr/bin/env bash
# run-in-docker.sh — run the prw test files in a throwaway bash 3.2 container,
# once per jq version in the matrix.
#
#   bash tests/run-in-docker.sh               # every tests/*.test.sh
#   bash tests/run-in-docker.sh wait.test.sh  # one file
#   PRW_JQ_MATRIX=1.7 bash tests/run-in-docker.sh
#
# bash 3.2 is the macOS system bash: passing here proves the scripts run on a
# stock Mac. The image carries only what prw may use: bash, jq, git, coreutils.
#
# jq 1.7 is what macOS ships (jq-1.7.1-apple) and it parses some expressions
# differently from 1.8: `A + B as $x | body` binds `as` to B alone under 1.7.
# On 2026-11-02 that silently dropped every PR wake on the host while a
# 1.8-only suite stayed green. Both versions are tested, and each leg checks
# the version it actually got.
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
only="${1:-}"
rc=0
for v in ${PRW_JQ_MATRIX:-1.7 1.8}; do
  case "$v" in
    1.7) install='apk add --no-cache -q --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/main "jq<1.8"' ;;
    1.8) install='apk add --no-cache -q "jq>=1.8"' ;;
    *) echo "unknown jq version in PRW_JQ_MATRIX: $v" >&2; exit 64 ;;
  esac
  echo "#### jq $v"
  docker run --rm -v "$SKILL_DIR:/skill:ro" -e ONLY="$only" -e WANT="jq-$v" bash:3.2 sh -c '
    apk add --no-cache -q git curl coreutils >/dev/null || exit 1
    '"$install"' >/dev/null || exit 1
    case "$(jq --version)" in "$WANT"*) ;; *) echo "wanted $WANT, got $(jq --version)"; exit 1 ;; esac
    rc=0
    for t in /skill/tests/*.test.sh; do
      [ -n "$ONLY" ] && [ "$(basename "$t")" != "$ONLY" ] && continue
      echo "== $(basename "$t")"
      bash "$t" || rc=1
    done
    exit $rc' || rc=1
done
exit $rc
