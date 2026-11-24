#!/usr/bin/env bash
# scan-iac.sh: white-box scan of a repository path, every tool in a version-tagged container.
#   trivy config   -> Kubernetes, Helm, Dockerfile, Compose-adjacent, Terraform, CloudFormation
#   trivy fs       -> committed secrets (secret scanner only)
#   hadolint       -> every Dockerfile found
#   kube-linter    -> Kubernetes manifests and Helm charts
#   checkov        -> --with-checkov (recommended; 581 MB image): checks the others lack (IAM wildcards,
#                     pods without NetworkPolicy, credentials inside connection strings)
#   ci-grep        -> P-05: secrets echoed or passed as --password in CI files; emits path:line:rule
#                     only, never the matching line (it may hold a literal credential)
# Raw reports go to the output directory, which must be outside the audited checkout
# (lib/out-guard.sh); a merged summary.json and a table are printed.
# No target host is contacted: the only network use is pulling images and trivy's check
# bundle, so this script has no authorization gate. The repository is mounted read-only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/out-guard.sh
. "$SCRIPT_DIR/lib/out-guard.sh"

TRIVY_IMAGE="${AUDIT_INFRA_TRIVY_IMAGE:-aquasec/trivy:0.76.2}"
HADOLINT_IMAGE="${AUDIT_INFRA_HADOLINT_IMAGE:-hadolint/hadolint:v2.15.1}"
KUBELINTER_IMAGE="${AUDIT_INFRA_KUBELINTER_IMAGE:-stackrox/kube-linter:v0.8.3}"
# kube-linter's default set skips the graph-level checks; these are added on purpose.
KUBELINTER_INCLUDE="${AUDIT_INFRA_KUBELINTER_INCLUDE:-non-isolated-pod,exposed-services,no-liveness-probe,no-readiness-probe,default-service-account,env-var-secret,read-secret-from-env-var,access-to-secrets,cluster-admin-role-binding,wildcard-in-rules,docker-sock,host-network,host-pid,host-ipc}"
CHECKOV_IMAGE="${AUDIT_INFRA_CHECKOV_IMAGE:-bridgecrew/checkov:3.4.9}"
TRIVY_CACHE_VOLUME="${AUDIT_INFRA_TRIVY_CACHE:-audit-infra-trivy-cache}"

usage() {
  cat <<'USAGE'
Usage: scan-iac.sh [options] <repo-path>

Options:
  --out DIR        Output directory, required, outside the audited checkout and not a
                   symlink: an existing directory, or one new level under one
                   (umask 077; OUT=$(mktemp -d); --out "$OUT/iac")
  --skip TOOLS     Comma-separated subset of: trivy,secrets,hadolint,kube-linter,ci-grep
  --with-checkov   Also run checkov (large image, slower; findings come without a
                   severity and are reported as UNRATED)
  --fail-on SEV    Exit 2 when a finding of this severity or above exists
                   (CRITICAL, HIGH, MEDIUM, LOW). Default: never fail on findings.
  -h, --help       Show this help

Outputs in DIR: trivy-config.json, trivy-secrets.json, hadolint.json,
kube-linter.json, ci-grep.json, checkov.json (with --with-checkov), summary.json.
USAGE
}

OUT=""; SKIP=""; FAIL_ON=""; TARGET=""; CHECKOV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --skip) SKIP="${2:-}"; shift 2 ;;
    --with-checkov) CHECKOV=1; shift ;;
    --fail-on) FAIL_ON="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; exit 1; }
case "$FAIL_ON" in ''|CRITICAL|HIGH|MEDIUM|LOW) : ;; *) die "--fail-on takes CRITICAL, HIGH, MEDIUM or LOW" ;; esac

need_docker
ensure_toolbox "$SCRIPT_DIR"
SRC="$(abs_path "$TARGET")"
OUT_ABS="$(check_out_dir "$OUT" "$SRC")" || exit 2
umask 077

skipped() { case ",$SKIP," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
note() { printf 'audit-infra: %s\n' "$*" >&2; }
TOOL_ERRORS=""

# --- trivy: misconfigurations ------------------------------------------------------
if ! skipped trivy; then
  note "trivy config ($TRIVY_IMAGE)"
  docker run --rm -v "$SRC:/src:ro" -v "$OUT_ABS:/out" -v "$TRIVY_CACHE_VOLUME:/root/.cache" \
    "$TRIVY_IMAGE" config --quiet --format json --output /out/trivy-config.json /src \
    2>"$OUT_ABS/trivy-config.log" || TOOL_ERRORS="$TOOL_ERRORS trivy"
fi
[ -s "$OUT_ABS/trivy-config.json" ] || echo '{"Results":[]}' >"$OUT_ABS/trivy-config.json"

# --- trivy: committed secrets --------------------------------------------------------
if ! skipped secrets; then
  note "trivy fs --scanners secret"
  docker run --rm -v "$SRC:/src:ro" -v "$OUT_ABS:/out" -v "$TRIVY_CACHE_VOLUME:/root/.cache" \
    "$TRIVY_IMAGE" fs --quiet --scanners secret --format json --output /out/trivy-secrets.json /src \
    2>"$OUT_ABS/trivy-secrets.log" || TOOL_ERRORS="$TOOL_ERRORS secrets"
fi
[ -s "$OUT_ABS/trivy-secrets.json" ] || echo '{"Results":[]}' >"$OUT_ABS/trivy-secrets.json"

# --- hadolint: one run per Dockerfile ------------------------------------------------
: >"$OUT_ABS/hadolint.ndjson"
if ! skipped hadolint; then
  note "hadolint ($HADOLINT_IMAGE)"
  ( cd "$SRC" && find . -type f \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' \) \
      -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' | sort ) |
  while IFS= read -r f; do
    f="${f#./}"
    docker run --rm -i "$HADOLINT_IMAGE" hadolint --no-fail -f json - <"$SRC/$f" 2>/dev/null |
      docker run --rm -i "$AUDIT_INFRA_TOOLBOX" jq -c --arg f "$f" '.[] | .file = $f' >>"$OUT_ABS/hadolint.ndjson" ||
      note "hadolint failed on $f"
  done
fi
docker run --rm -i "$AUDIT_INFRA_TOOLBOX" jq -s . <"$OUT_ABS/hadolint.ndjson" >"$OUT_ABS/hadolint.json"
rm -f "$OUT_ABS/hadolint.ndjson"

# --- kube-linter -----------------------------------------------------------------------
if ! skipped kube-linter; then
  note "kube-linter ($KUBELINTER_IMAGE)"
  # Exit code 1 means "findings", not "failure"; only an empty report is an error.
  docker run --rm -v "$SRC:/src:ro" "$KUBELINTER_IMAGE" lint /src --format json --include "$KUBELINTER_INCLUDE" \
    >"$OUT_ABS/kube-linter.json" 2>"$OUT_ABS/kube-linter.log"
fi
if ! docker run --rm -i "$AUDIT_INFRA_TOOLBOX" jq -e . <"$OUT_ABS/kube-linter.json" >/dev/null 2>&1; then
  skipped kube-linter || { grep -qi 'no valid objects found' "$OUT_ABS/kube-linter.log" 2>/dev/null || TOOL_ERRORS="$TOOL_ERRORS kube-linter"; }
  echo '{"Reports":[]}' >"$OUT_ABS/kube-linter.json"
fi

# --- ci-grep: P-05 secret handling in CI files --------------------------------------
# The match runs inside the container and prints file, line and rule id only: the
# matching line itself may carry a literal password and must never reach a transcript.
: >"$OUT_ABS/ci-grep.json"
if ! skipped ci-grep; then
  note "ci-grep (P-05)"
  docker run --rm --network none -v "$SRC:/src:ro" "$AUDIT_INFRA_TOOLBOX" sh -c '
    cd /src && find . -type f \( -path "./.github/workflows/*" -o -name ".gitlab-ci.yml" \
        -o -name "azure-pipelines.yml" -o -name "bitbucket-pipelines.yml" -o -name "Jenkinsfile" \
        -o -path "./.circleci/*" \) -not -path "*/.git/*" -not -path "*/node_modules/*" | sort |
    while IFS= read -r f; do
      awk -v f="${f#./}" '"'"'
        { l = tolower($0) }
        l ~ /--password-stdin/ { next }
        l ~ /(echo|printf)[^#]*(secrets\.|\$\{?[a-z_]*(secret|token|password|passwd|api_key))/ { print f "\t" NR "\tP-05-echo"; next }
        l ~ /--(password|passwd)([= ]|$)/ { print f "\t" NR "\tP-05-cli-arg" }
      '"'"' "$f" 2>/dev/null
    done' 2>/dev/null |
    docker run --rm -i "$AUDIT_INFRA_TOOLBOX" jq -R -s -c '
      [ split("\n")[] | select(length > 0) | split("\t")
        | {file: .[0], line: (.[1] | tonumber), rule: .[2]} ]' >"$OUT_ABS/ci-grep.json" ||
    TOOL_ERRORS="$TOOL_ERRORS ci-grep"
fi
[ -s "$OUT_ABS/ci-grep.json" ] || echo '[]' >"$OUT_ABS/ci-grep.json"

# --- checkov (opt-in) ----------------------------------------------------------------------
if [ "$CHECKOV" -eq 1 ]; then
  note "checkov ($CHECKOV_IMAGE)"
  # Exit code 1 means "failed checks". Output is one object, or an array of one per framework.
  docker run --rm -v "$SRC:/src:ro" "$CHECKOV_IMAGE" -d /src --quiet --compact --output json \
    >"$OUT_ABS/checkov.json" 2>"$OUT_ABS/checkov.log"
  docker run --rm -i "$AUDIT_INFRA_TOOLBOX" jq -e . <"$OUT_ABS/checkov.json" >/dev/null 2>&1 ||
    { TOOL_ERRORS="$TOOL_ERRORS checkov"; echo '[]' >"$OUT_ABS/checkov.json"; }
else
  echo '[]' >"$OUT_ABS/checkov.json.tmp"
fi
[ -f "$OUT_ABS/checkov.json.tmp" ] && CHECKOV_FILE=checkov.json.tmp || CHECKOV_FILE=checkov.json

# --- merge -------------------------------------------------------------------------------
docker run --rm -v "$OUT_ABS:/out" --user 0 "$AUDIT_INFRA_TOOLBOX" sh -c '
  jq -n --arg target "$1" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg errors "$2" \
    --arg trivy "$3" --arg hadolint "$4" --arg kubelinter "$5" \
    --slurpfile t /out/trivy-config.json --slurpfile s /out/trivy-secrets.json \
    --slurpfile h /out/hadolint.json --slurpfile k /out/kube-linter.json --slurpfile g /out/ci-grep.json --slurpfile c "/out/$6" '"'"'
    def sev_rank: {"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1,"UNKNOWN":0};
    def hl: {"error":"HIGH","warning":"MEDIUM","info":"LOW","style":"LOW"};
    ( [ $t[0].Results[]? | .Target as $f | .Type as $ty | .Misconfigurations[]?
        | {tool:"trivy", severity:.Severity, id:.ID, file:$f, kind:$ty,
           line:(.CauseMetadata.StartLine // null), title:.Title, fix:(.Resolution // null)} ]
    + [ $s[0].Results[]? | .Target as $f | .Secrets[]?
        | {tool:"trivy-secret", severity:.Severity, id:.RuleID, file:$f, kind:"secret",
           line:(.StartLine // null), title:.Title, fix:"Rotate the credential, then remove it from history"} ]
    + [ $h[0][]? | {tool:"hadolint", severity:(hl[.level] // "LOW"), id:.code, file:.file,
           kind:"dockerfile", line:.line, title:.message, fix:null} ]
    + [ $k[0].Reports[]? | {tool:"kube-linter", severity:"MEDIUM", id:.Check,
           file:(.Object.Metadata.FilePath // null | if . then sub("^/src/";"") else . end),
           kind:((.Object.K8sObject.GroupVersionKind.Kind // "?") + "/" + (.Object.K8sObject.Name // "?")),
           line:null, title:.Diagnostic.Message, fix:(.Remediation // null)} ]
    + [ $g[0][]? | {tool:"ci-grep", severity:"MEDIUM", id:"P-05", file:.file, kind:"ci", line:.line,
           title:(if .rule == "P-05-echo" then "a secret reference is echoed or printed in a CI step"
                  else "a password is passed as a command-line argument in a CI step" end),
           fix:"Pass the secret through an environment variable or --password-stdin; never print it"} ]
    + [ $c[0] | (if type == "array" then .[] else . end) | .check_type as $ty | .results.failed_checks[]?
        | {tool:"checkov", severity:(.severity // "UNRATED"), id:.check_id, file:(.file_path | sub("^/";"")),
           kind:$ty, line:(.file_line_range[0] // null), title:.check_name, fix:(.guideline // null)} ]
    ) as $all
    | { target: $target, scanned_at: $at,
        tools: {trivy: $trivy, hadolint: $hadolint, "kube-linter": $kubelinter},
        tool_errors: ($errors | split(" ") | map(select(length > 0))),
        counts: { total: ($all | length),
                  by_tool: ($all | group_by(.tool) | map({key: .[0].tool, value: length}) | from_entries),
                  by_severity: ($all | group_by(.severity) | map({key: .[0].severity, value: length}) | from_entries) },
        findings: ($all | sort_by([-(sev_rank[.severity] // 0), .tool, .file, .id])) }
  '"'"' >/out/summary.json
  jq -r '"'"'
    "target: \(.target)", "findings: \(.counts.total)  by severity: \(.counts.by_severity | tojson)  by tool: \(.counts.by_tool | tojson)",
    (if (.tool_errors | length) > 0 then "TOOL ERRORS (results incomplete): \(.tool_errors | join(", "))" else empty end), "",
    (["SEVERITY","TOOL","ID","COUNT","FILE","TITLE"] | @tsv),
    (.findings | group_by([.severity, .tool, .id, .file]) | map(.[0] + {count: length})
     | sort_by([-({"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1}[.severity] // 0), .tool, .file, .id])[]
     | [.severity, .tool, .id, .count, ((.file // "-") + (if .line then ":\(.line)" else "" end)), (.title | gsub("[\\n\\t]";" ") | .[0:90])] | @tsv)
  '"'"' /out/summary.json
' sh "$SRC" "$TOOL_ERRORS" "$TRIVY_IMAGE" "$HADOLINT_IMAGE" "$KUBELINTER_IMAGE" "$CHECKOV_FILE"
rm -f "$OUT_ABS/checkov.json.tmp"

note "reports in $OUT_ABS"
[ -z "$TOOL_ERRORS" ] || { note "tool errors:$TOOL_ERRORS (see the .log files)"; exit 1; }
if [ -n "$FAIL_ON" ]; then
  docker run --rm -i "$AUDIT_INFRA_TOOLBOX" jq -e --arg s "$FAIL_ON" '
    {"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1} as $r | [.findings[] | select(($r[.severity] // 0) >= $r[$s])] | length == 0
  ' <"$OUT_ABS/summary.json" >/dev/null || exit 2
fi
exit 0
