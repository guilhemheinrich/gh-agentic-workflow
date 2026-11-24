#!/usr/bin/env bash
# audit-schema.sh - read-only PostgreSQL audit, run through the psql of the
# postgres:16 image (a major-version tag; set AUDIT_PSQL_IMAGE to an image
# digest for a reproducible run). Nothing is installed on the host.
#
# The connection string is taken from an environment variable (default
# AUDIT_DATABASE_URL). It is forwarded to the container through the
# environment, never placed on the docker command line, never printed, never
# written to a file. Inside the container the password is moved to PGPASSWORD,
# so no process argument list holds it (lib/run-checks.sh).
#
#   export AUDIT_DATABASE_URL   # set it from your secret store, not on a command line
#   scripts/audit-schema.sh --format markdown --output audit-findings.md
#   scripts/audit-schema.sh --schemas public,billing --with-data --fail-on high
#
# Exit codes: 0 audit completed, 1 usage or connection error,
#             2 --fail-on threshold reached.
set -euo pipefail

IMAGE="${AUDIT_PSQL_IMAGE:-postgres:16}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${AUDIT_SQL_DIR:-$HERE/sql}"

env_var="AUDIT_DATABASE_URL"
format="json"; output=""; schemas=""; only=""; skip=""; with_data=0
max_rows=200; timeout="60s"; network=""; fail_on=""; sets=""; ca_file=""

usage() {
  cat <<'EOF'
Usage: audit-schema.sh [options]

  --env-var NAME      environment variable holding the connection string
                      (default AUDIT_DATABASE_URL)
  --format FMT        json (default) or markdown
  --output FILE       write the document to FILE instead of stdout
  --schemas A,B       restrict to these schemas (default: all non-system)
  --only REGEX        run only checks whose id matches (e.g. '^REL-|^TEN-')
  --skip REGEX        skip checks whose id matches
  --with-data         also run the data probes (they read rows: orphans,
                      discriminator values, JSON keys). Off by default.
  --max-rows N        findings listed per check (default 200; count is exact)
  --timeout DUR       statement_timeout per check (default 60s)
  --network NAME      docker network (e.g. host, container:<name>, my_net)
  --ca-file PATH      CA certificate used to verify the server; pair it with
                      sslmode=verify-full in the connection string (without
                      it, PostgreSQL 16+ clients accept sslrootcert=system)
  --set NAME=VALUE    override a threshold: probe_rows, min_rows,
                      n1_min_calls, long_tx_seconds, dead_min, xid_age_warn,
                      seq_pct, tenant_col, ignore_tables
  --fail-on SEV       exit 2 if a finding of this severity or above exists
                      (critical|high|medium|low|info)
  --list              list the checks and exit (no database needed)
  -h, --help          this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-var) env_var="$2"; shift 2 ;;
    --format) format="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --schemas) schemas="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --skip) skip="$2"; shift 2 ;;
    --with-data) with_data=1; shift ;;
    --max-rows) max_rows="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --network) network="$2"; shift 2 ;;
    --ca-file) ca_file="$2"; shift 2 ;;
    --set) sets+="$2"$'\n'; shift 2 ;;
    --fail-on) fail_on="$2"; shift 2 ;;
    --list)
      for f in "$SQL_DIR"/*.sql; do
        printf '%-8s %-9s %s%s\n' "$(sed -n 's/^-- id: *//p' "$f")" "$(sed -n 's/^-- severity: *//p' "$f")" \
          "$(sed -n 's/^-- title: *//p' "$f")" \
          "$(grep -q '^-- data-probe: true' "$f" && echo '  [data probe]' || true)"
      done
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "audit-schema.sh: unknown option $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$format" in json|markdown) ;; *) echo "audit-schema.sh: --format must be json or markdown" >&2; exit 1 ;; esac
case "$fail_on" in ""|critical|high|medium|low|info) ;; *) echo "audit-schema.sh: invalid --fail-on" >&2; exit 1 ;; esac
[[ "$env_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "audit-schema.sh: invalid --env-var name" >&2; exit 1; }
if [[ -z "${!env_var:-}" ]]; then
  echo "audit-schema.sh: environment variable $env_var is empty or unset (it must hold the connection string)" >&2
  exit 1
fi
command -v docker >/dev/null || { echo "audit-schema.sh: docker is required" >&2; exit 1; }

docker_args=(run --rm --label audit-database=1
  --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp
  -v "$SQL_DIR:/audit/sql:ro" -v "$HERE/lib:/audit/lib:ro"
  -e AUDIT_DB_URL
  -e "AUDIT_FORMAT=$format" -e "AUDIT_SCHEMAS=$schemas" -e "AUDIT_ONLY=$only" -e "AUDIT_SKIP=$skip"
  -e "AUDIT_WITH_DATA=$with_data" -e "AUDIT_MAX_ROWS=$max_rows" -e "AUDIT_TIMEOUT=$timeout"
  -e "AUDIT_FAIL_ON=$fail_on" -e "AUDIT_SETS=$sets"
  -e PGCONNECT_TIMEOUT=10)
[[ -n "$network" ]] && docker_args+=(--network "$network")
if [[ -n "$ca_file" ]]; then
  [[ -r "$ca_file" ]] || { echo "audit-schema.sh: --ca-file $ca_file is not readable" >&2; exit 1; }
  docker_args+=(-v "$(cd "$(dirname "$ca_file")" && pwd)/$(basename "$ca_file"):/audit/ca.pem:ro" -e PGSSLROOTCERT=/audit/ca.pem)
fi
# host.docker.internal reaches a database on the host from the default bridge
# or a user network. Docker refuses --add-host together with container:<name>;
# with --network host on Linux the host is simply localhost.
[[ "$network" == container:* ]] || docker_args+=(--add-host host.docker.internal:host-gateway)
docker_args+=(--entrypoint bash "$IMAGE" /audit/lib/run-checks.sh)

# The value travels in the docker client's environment only (`-e NAME` with no
# value copies it from there), so it never appears in `ps` or shell history.
if [[ -n "$output" ]]; then
  AUDIT_DB_URL="${!env_var}" docker "${docker_args[@]}" >"$output"
  echo "audit-schema.sh: wrote $output" >&2
else
  AUDIT_DB_URL="${!env_var}" docker "${docker_args[@]}"
fi
