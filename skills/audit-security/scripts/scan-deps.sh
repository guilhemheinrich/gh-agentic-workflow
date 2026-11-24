#!/usr/bin/env bash
# scan-deps.sh - list known vulnerabilities in a project's dependencies.
#
# Docker-only: nothing is installed on the host. Fallback chain:
#   1. osv-scanner (reads every lockfile/manifest it knows, all ecosystems)
#   2. OSV.dev HTTP API through curl + jq containers (npm package-lock.json
#      v2/v3 and pinned requirements.txt only)
# Both paths write the same normalised file, <out>/deps-findings.json, which
# enrich-kev-epss.py consumes.
#
# Coverage is written to <out>/deps-coverage.json: which path ran, which
# manifests were read, how many packages each gave, what was skipped. Identical
# output shape does not mean identical coverage: read that file.
#
# Exit codes: 0 = no known vulnerability, 1 = at least one,
#             2 = scan failed OR incomplete (findings may still be written).
set -euo pipefail

OSV_SCANNER_IMAGE="${OSV_SCANNER_IMAGE:-ghcr.io/google/osv-scanner:v2.7.1}"
JQ_IMAGE="${JQ_IMAGE:-ghcr.io/jqlang/jq:1.8.2}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.23.0}"
OSV_API="${OSV_API:-https://api.osv.dev}"

usage() {
  cat <<'EOF'
Usage: scan-deps.sh [--out DIR] [--mode auto|osv-scanner|api] [TARGET_DIR]

  TARGET_DIR   project to scan (default: current directory)
  --out DIR    where reports are written (required, or $SECURITY_AUDIT_OUT; a fresh
               directory outside the checkout: OUT=$(mktemp -d))
  --mode       auto (default) tries osv-scanner then the OSV API;
               osv-scanner / api force one path

Outputs in DIR:
  deps-findings.json   one object per (package, vulnerability)
  deps-coverage.json   path used, manifests read, package counts, skips
  deps-hygiene.json    npm lockfile/pinning warnings (not vulnerabilities)
  osv-scanner.json     raw osv-scanner report (osv-scanner path only)
EOF
}

OUT="${SECURITY_AUDIT_OUT:-}"
MODE="auto"
TARGET="."
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
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

jq_run() { docker run --rm -i -v "$OUT":/out "$JQ_IMAGE" "$@"; }

# Same shape whichever path produced the data.
NORMALISE_OSV_SCANNER='
[ .results[]?
  | .source.path as $src
  | .packages[]?
  | .package as $p
  | .vulnerabilities[]?
  | {
      ecosystem: $p.ecosystem, name: $p.name, version: $p.version,
      source: ($src | sub("^/src/"; "")),
      id: .id,
      cves: ([.id, (.aliases // [])[]] | map(select(startswith("CVE-"))) | unique),
      summary: (.summary // (.details // "" | .[0:120])),
      cvss_vector: ((.severity // []) | (map(select(.type == "CVSS_V3"))[0] // .[0] // {}) | .score // null),
      advisory_severity: (.database_specific.severity // null),
      cwes: (.database_specific.cwe_ids // []),
      fixed: ([.affected[]? | select(.package.name == $p.name) | .ranges[]?.events[]? | .fixed // empty] | unique)
    }
]'

run_osv_scanner() {
  echo "[deps] osv-scanner ($OSV_SCANNER_IMAGE)" >&2
  local rc=0
  docker run --rm -v "$TARGET":/src:ro "$OSV_SCANNER_IMAGE" \
    scan source --recursive --all-packages --format json /src \
    >"$OUT/osv-scanner.json" 2>"$OUT/osv-scanner.log" || rc=$?
  # 0 = clean, 1 = vulnerabilities found; anything else is a tool failure
  # (128 = no package source found).
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "[deps] osv-scanner failed (exit $rc), see $OUT/osv-scanner.log" >&2
    return 1
  fi
  jq_run "$NORMALISE_OSV_SCANNER" <"$OUT/osv-scanner.json" >"$OUT/deps-findings.json"
  jq_run '{path: "osv-scanner", incomplete: false, skipped: [],
           sources: [.results[]? | {source: (.source.path | sub("^/src/"; "")), packages: (.packages | length)}]}' \
    <"$OUT/osv-scanner.json" >"$OUT/deps-coverage.json"
}

# Manifests the API fallback cannot read. Listed so that a skip is visible.
API_UNSUPPORTED="pnpm-lock.yaml yarn.lock poetry.lock uv.lock Pipfile.lock pyproject.toml go.mod Cargo.lock composer.lock pom.xml build.gradle Gemfile.lock"

run_osv_api() {
  echo "[deps] OSV API fallback ($OSV_API)" >&2
  local pkgs="$OUT/.deps-packages.json"
  : >"$OUT/.deps-packages.ndjson"
  if [ -f "$TARGET/package-lock.json" ]; then
    jq_run -c '
      (.packages // {}) | to_entries[]
      | select(.key | test("node_modules/"))
      | select(.value.version != null and (.value.link // false | not))
      | {ecosystem: "npm", name: (.key | sub("^.*node_modules/"; "")),
         version: .value.version, source: "package-lock.json"}' \
      <"$TARGET/package-lock.json" >>"$OUT/.deps-packages.ndjson"
  fi
  if [ -f "$TARGET/requirements.txt" ]; then
    jq_run -R -c '
      capture("^\\s*(?<name>[A-Za-z0-9._-]+)\\s*==\\s*(?<version>[^\\s;#]+)")
      | {ecosystem: "PyPI", name, version, source: "requirements.txt"}' \
      <"$TARGET/requirements.txt" >>"$OUT/.deps-packages.ndjson"
  fi
  jq_run -s 'unique_by([.ecosystem, .name, .version])' <"$OUT/.deps-packages.ndjson" >"$pkgs"
  local count
  count="$(jq_run 'length' <"$pkgs")"
  if [ "$count" -eq 0 ]; then
    echo "[deps] API fallback found no package-lock.json (v2/v3) or pinned requirements.txt" >&2
    return 1
  fi
  echo "[deps] $count packages to query" >&2

  # /v1/querybatch accepts at most 1000 queries and returns only {id, modified}.
  : >"$OUT/.deps-batch.ndjson"
  local offset=0
  while [ "$offset" -lt "$count" ]; do
    jq_run -c --argjson o "$offset" '
      {queries: [.[$o:$o+1000][] | {package: {name, ecosystem}, version}]}' <"$pkgs" \
      | docker run --rm -i "$CURL_IMAGE" -sS --fail --max-time 60 \
          -H 'Content-Type: application/json' -X POST --data-binary @- \
          "$OSV_API/v1/querybatch" >>"$OUT/.deps-batch.ndjson"
    echo >>"$OUT/.deps-batch.ndjson"
    offset=$((offset + 1000))
  done
  jq_run -s '[.[].results[]]' <"$OUT/.deps-batch.ndjson" >"$OUT/.deps-batch.json"
  local paginated skipped="" f
  paginated="$(jq_run '[.[] | select(.next_page_token != null)] | length' <"$OUT/.deps-batch.json")"
  for f in $API_UNSUPPORTED; do [ ! -f "$TARGET/$f" ] || skipped="$skipped $f"; done

  # Full records, one GET /v1/vulns/{id} per distinct id, in a single container.
  local ids
  ids="$(jq_run -r '[.[].vulns[]?.id] | unique | .[]' <"$OUT/.deps-batch.json")"
  if [ -z "$ids" ]; then
    echo '[]' >"$OUT/.deps-vulns.json"
  else
    local urls=()
    while IFS= read -r id; do urls+=("$OSV_API/v1/vulns/$id"); done <<<"$ids"
    docker run --rm "$CURL_IMAGE" -sS --fail --max-time 120 "${urls[@]}" \
      | jq_run -s '.' >"$OUT/.deps-vulns.json"
  fi

  cat "$pkgs" "$OUT/.deps-batch.json" "$OUT/.deps-vulns.json" | jq_run -n '
    (input) as $pkgs | (input) as $batch | (input | map({key: .id, value: .}) | from_entries) as $vulns
    | [ range(0; $pkgs | length) as $i
        | $pkgs[$i] as $p
        | ($batch[$i].vulns // [])[]
        | $vulns[.id] as $v
        | {
            ecosystem: $p.ecosystem, name: $p.name, version: $p.version, source: $p.source,
            id: $v.id,
            cves: ([$v.id, ($v.aliases // [])[]] | map(select(startswith("CVE-"))) | unique),
            summary: ($v.summary // ($v.details // "" | .[0:120])),
            cvss_vector: (($v.severity // []) | (map(select(.type == "CVSS_V3"))[0] // .[0] // {}) | .score // null),
            advisory_severity: ($v.database_specific.severity // null),
            cwes: ($v.database_specific.cwe_ids // []),
            fixed: ([$v.affected[]? | select(.package.name == $p.name) | .ranges[]?.events[]? | .fixed // empty] | unique)
          } ]' >"$OUT/deps-findings.json"
  jq_run --argjson paginated "$paginated" --arg skipped "$skipped" '
    ($skipped | split(" ") | map(select(. != ""))) as $s
    | {path: "osv-api", incomplete: ($paginated > 0 or ($s | length) > 0),
       skipped: ($s | map({source: ., reason: "format not read by the API fallback"})),
       paginated_queries: $paginated, note: "root directory only, no recursion",
       sources: (group_by(.source) | map({source: .[0].source, packages: length}))}' \
    <"$pkgs" >"$OUT/deps-coverage.json"
  rm -f "$OUT"/.deps-*
}

# npm-only hygiene: facts a vulnerability database cannot know.
run_hygiene() {
  local warnings="$OUT/.hygiene.ndjson"
  : >"$warnings"
  if [ -f "$TARGET/package.json" ]; then
    if [ ! -f "$TARGET/package-lock.json" ] && [ ! -f "$TARGET/pnpm-lock.yaml" ] && [ ! -f "$TARGET/yarn.lock" ]; then
      echo '{"check":"lockfile-missing","detail":"package.json without any lockfile: installs are not reproducible"}' >>"$warnings"
    fi
    jq_run -c '
      [(.dependencies // {}), (.devDependencies // {}), (.optionalDependencies // {})] | add // {} | to_entries[]
      | if (.value | test("^(git\\+|git:|https?:|github:|file:)")) then
          {check: "non-registry-source", detail: "\(.key)@\(.value) bypasses the registry and its advisories"}
        elif (.value | test("^(\\*|latest|x)$|^[\\^~><]|\\s-\\s|\\|\\|")) then
          {check: "range-specifier", detail: "\(.key)@\(.value) is a range: only the lockfile pins it"}
        else empty end' <"$TARGET/package.json" >>"$warnings"
  fi
  if [ -f "$TARGET/package-lock.json" ]; then
    jq_run -c '
      (.packages // {}) | to_entries[] | select(.key != "")
      | (.key | sub("^.*node_modules/"; "")) as $n
      | (if .value.hasInstallScript then {check: "install-script", detail: "\($n)@\(.value.version) runs a script at install time"} else empty end),
        (if (.value.link // false | not) and (.value.resolved != null) and (.value.integrity == null)
           then {check: "integrity-missing", detail: "\($n)@\(.value.version) has no integrity hash"} else empty end),
        (if (.value.resolved // "" | test("^https://registry\\.npmjs\\.org/|^$") | not)
           then {check: "non-default-registry", detail: "\($n) resolved from \(.value.resolved | sub("^(?<h>[a-z+]+://[^/]+).*"; "\(.h)"))"} else empty end)' \
      <"$TARGET/package-lock.json" >>"$warnings"
  fi
  jq_run -s '.' <"$warnings" >"$OUT/deps-hygiene.json"
  rm -f "$warnings"
}

ok=1
case "$MODE" in
  osv-scanner) run_osv_scanner && ok=0 ;;
  api) run_osv_api && ok=0 ;;
  auto) { run_osv_scanner || run_osv_api; } && ok=0 ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
if [ "$ok" -ne 0 ]; then
  echo "[deps] no scan path succeeded: this is NOT a clean result" >&2
  exit 2
fi
run_hygiene

jq_run -r '"[deps] coverage (\(.path)): " + ([.sources[] | "\(.source)=\(.packages) pkg"] | join(", "))' <"$OUT/deps-coverage.json" >&2
incomplete="$(jq_run -r '.incomplete' <"$OUT/deps-coverage.json")"
total="$(jq_run 'length' <"$OUT/deps-findings.json")"
echo "[deps] $total (package, vulnerability) pairs -> $OUT/deps-findings.json" >&2
jq_run -r '
  group_by([.name, .version])[]
  | "\(.[0].ecosystem) \(.[0].name)@\(.[0].version): \(length) vuln(s) [\([.[].id] | join(", "))]"' \
  <"$OUT/deps-findings.json"
hygiene="$(jq_run 'length' <"$OUT/deps-hygiene.json")"
[ "$hygiene" -eq 0 ] || { echo "[deps] $hygiene hygiene warning(s) -> $OUT/deps-hygiene.json" >&2
  jq_run -r '.[] | "hygiene \(.check): \(.detail)"' <"$OUT/deps-hygiene.json"; }
if [ "$incomplete" = "true" ]; then
  jq_run -r '"[deps] INCOMPLETE: skipped [\([.skipped[].source] | join(", "))], \(.paginated_queries // 0) paginated quer(y/ies). Report this as not fully scanned; use osv-scanner."' <"$OUT/deps-coverage.json" >&2
  exit 2
fi
[ "$total" -eq 0 ] && exit 0 || exit 1
