#!/usr/bin/env bash
# scan-sast.sh - static analysis of the source code with semgrep, in Docker.
#
# Rulesets are picked from the files present (always p/default,
# p/owasp-top-ten and p/security-audit), fetched
# from the semgrep registry at run time: the scan needs network access to
# semgrep.dev, and sends no code or metrics (--metrics=off).
#
# A clean run proves little: semgrep matches patterns, it does not understand
# who may access what. Follow it with references/sast-expert-checklist.md.
#
# Exit codes: 0 = no finding, 1 = at least one finding, 2 = scan failed.
set -euo pipefail

SEMGREP_IMAGE="${SEMGREP_IMAGE:-semgrep/semgrep:1.186.0}"
JQ_IMAGE="${JQ_IMAGE:-ghcr.io/jqlang/jq:1.8.2}"

usage() {
  cat <<'EOF'
Usage: scan-sast.sh [--out DIR] [--config RULESET ...] [--exclude GLOB ...] [TARGET_DIR]

  TARGET_DIR   project to scan (default: current directory)
  --out DIR    where reports are written (required, or $SECURITY_AUDIT_OUT; a fresh
               directory outside the checkout: OUT=$(mktemp -d))
  --config     add a ruleset (p/jwt, p/xss, p/sql-injection, p/command-injection,
               p/secrets, p/security-audit, a local rules.yml, ...); repeatable
  --exclude    path glob to skip (repeatable); .semgrepignore and .gitignore
               are honoured by semgrep itself

Outputs in DIR:
  sast-semgrep.json    raw semgrep report
  sast-findings.json   one flat object per finding (rule, file, line, CWE, OWASP)
EOF
}

OUT="${SECURITY_AUDIT_OUT:-}"
TARGET="."
EXTRA_CONFIGS=()
EXCLUDES=()
MOUNT_RULES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --config) EXTRA_CONFIGS+=("$2"); shift 2 ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "not a directory: $TARGET" >&2; exit 2; }
TARGET="$(cd "$TARGET" && pwd)"
. "$(dirname "$0")/out-guard.sh"
check_out_dir "$TARGET"

has() { # true when at least one file with one of the given extensions exists
  local args=() ext
  for ext in "$@"; do args+=(-o -name "*.$ext"); done
  [ -n "$(find "$TARGET" \( -name node_modules -o -name .git -o -name vendor -o -name dist -o -name build -o -name .venv \) -prune \
    -o -type f \( "${args[@]:1}" \) -print 2>/dev/null | head -n 1)" ]
}

CONFIGS=(p/default p/owasp-top-ten p/security-audit)
if has js jsx mjs cjs; then CONFIGS+=(p/javascript p/nodejs); fi
if has ts tsx; then CONFIGS+=(p/typescript); fi
if has jsx tsx; then CONFIGS+=(p/react); fi
if has py; then CONFIGS+=(p/python); fi
if has go; then CONFIGS+=(p/golang); fi
if has java kt; then CONFIGS+=(p/java); fi
if has php; then CONFIGS+=(p/php); fi
[ ${#EXTRA_CONFIGS[@]} -eq 0 ] || CONFIGS+=("${EXTRA_CONFIGS[@]}")

args=(scan --metrics=off --json --output /out/sast-semgrep.json --quiet)
for c in "${CONFIGS[@]}"; do
  if [ -f "$c" ]; then
    abs="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"
    MOUNT_RULES+=(-v "$abs":"/rules/$(basename "$c")":ro)
    args+=(--config "/rules/$(basename "$c")")
  else
    args+=(--config "$c")
  fi
done
[ ${#EXCLUDES[@]} -eq 0 ] || for e in "${EXCLUDES[@]}"; do args+=(--exclude "$e"); done

echo "[sast] semgrep ($SEMGREP_IMAGE) with: ${CONFIGS[*]}" >&2
rc=0
docker run --rm -v "$TARGET":/src:ro -v "$OUT":/out ${MOUNT_RULES[@]+"${MOUNT_RULES[@]}"} -w /src \
  "$SEMGREP_IMAGE" semgrep "${args[@]}" /src >"$OUT/sast-semgrep.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$OUT/sast-semgrep.json" ]; then
  echo "[sast] semgrep failed (exit $rc), see $OUT/sast-semgrep.log: this is NOT a clean result" >&2
  exit 2
fi

jq_run() { docker run --rm -i "$JQ_IMAGE" "$@"; }
jq_run '
  def arr: if type == "array" then . elif . == null then [] else [.] end;
  [ .results[]
    | {
        rule: .check_id,
        file: (.path | sub("^/src/"; "")),
        line: .start.line,
        severity: .extra.severity,
        confidence: (.extra.metadata.confidence // null),
        cwe: (.extra.metadata.cwe | arr | map(capture("(?<id>CWE-[0-9]+)").id)),
        owasp: (.extra.metadata.owasp | arr),
        message: (.extra.message | gsub("\\s+"; " ") | .[0:200])
      } ]
  | unique_by([.file, .line, (.cwe | join(","))])
  | sort_by(.file, .line)' <"$OUT/sast-semgrep.json" >"$OUT/sast-findings.json"

total="$(jq_run 'length' <"$OUT/sast-findings.json")"
errors="$(jq_run '.errors | length' <"$OUT/sast-semgrep.json")"
scanned="$(jq_run '.paths.scanned | length' <"$OUT/sast-semgrep.json")"
echo "[sast] $scanned file(s) scanned, $total finding(s), $errors semgrep error(s) -> $OUT/sast-findings.json" >&2
[ "$errors" -eq 0 ] || echo "[sast] INCOMPLETE: $errors file(s) or rule(s) failed, read .errors in sast-semgrep.json and list them as not covered" >&2
[ "$scanned" -gt 0 ] || { echo "[sast] nothing was scanned: this is NOT a clean result" >&2; exit 2; }
jq_run -r '.[] | "\(.severity) \(.file):\(.line) \(.cwe | join(",")) \(.rule | split(".") | .[-1])"' <"$OUT/sast-findings.json"
[ "$total" -eq 0 ] && exit 0 || exit 1
