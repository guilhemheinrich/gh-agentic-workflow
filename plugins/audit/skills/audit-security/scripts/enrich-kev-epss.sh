#!/usr/bin/env bash
# enrich-kev-epss.sh - Docker wrapper around enrich-kev-epss.py.
#
# Adds CISA KEV membership, EPSS score and a computed CVSS base score to the
# deps-findings.json written by scan-deps.sh, then ranks findings P0..P3.
#
# Exit codes: 0 = nothing at P0/P1, 1 = at least one P0/P1, 2 = failure
# (including an unreachable KEV or EPSS endpoint: no partial triage is written).
set -euo pipefail

PYTHON_IMAGE="${PYTHON_IMAGE:-python:3.12-slim}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
Usage: enrich-kev-epss.sh [OUT_DIR] [--cve CVE-YYYY-NNNN ...]

  OUT_DIR   directory holding deps-findings.json (or $SECURITY_AUDIT_OUT);
            deps-triage.json and deps-triage.md are written next to it
  --cve     rank bare CVE ids, with or without a findings file
EOF
  exit 0
fi

OUT="${SECURITY_AUDIT_OUT:-}"
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then OUT="$1"; shift; fi
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
. "$(dirname "$0")/out-guard.sh"
check_out_dir
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

findings=()
[ -f "$OUT/deps-findings.json" ] && findings=(/out/deps-findings.json)

# -I: isolated mode, the interpreter ignores PYTHON* variables and the
# script directory, so nothing in the mounted folders can shadow a module.
docker run --rm -v "$OUT":/out -v "$SCRIPTS":/scripts:ro "$PYTHON_IMAGE" \
  python -I /scripts/enrich-kev-epss.py ${findings[@]+"${findings[@]}"} --out /out "$@"
