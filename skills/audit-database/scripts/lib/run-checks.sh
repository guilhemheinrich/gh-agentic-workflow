#!/usr/bin/env bash
# Runs INSIDE the postgres image (started by ../audit-schema.sh).
# Executes every check under $AUDIT_SQL_DIR in its own read-only transaction
# and assembles one JSON or markdown document on stdout. Progress goes to
# stderr. The connection string is read from AUDIT_DB_URL and never printed.
set -uo pipefail

: "${AUDIT_DB_URL:?AUDIT_DB_URL is not set}"

# Keep the password out of every process argument list (argv is readable with
# `ps` / `docker top`, on a Linux host too): move it from the connection string
# to PGPASSWORD, which libpq reads from the environment. psql then receives a
# connection string that names host, user and database but carries no secret.
urldecode() { local s="${1//\\/\\\\}"; printf '%b' "${s//%/\\x}"; }
CONN="$AUDIT_DB_URL"
if [[ "$CONN" =~ ^(postgres(ql)?://[^:@/?]*):([^@/?]*)@(.*)$ ]]; then            # URI: user:password@host
  PGPASSWORD="$(urldecode "${BASH_REMATCH[3]}")"; CONN="${BASH_REMATCH[1]}@${BASH_REMATCH[4]}"
elif [[ "$CONN" =~ ^(postgres(ql)?://.*[?\&])password=([^\&]*)\&?(.*)$ ]]; then  # URI: ?password=
  PGPASSWORD="$(urldecode "${BASH_REMATCH[3]}")"; CONN="${BASH_REMATCH[1]}${BASH_REMATCH[4]}"
elif [[ "$CONN" =~ ^(.*[[:space:]])?password=([^[:space:]\']+)(.*)$ ]]; then      # keyword=value, unquoted
  PGPASSWORD="${BASH_REMATCH[2]}"; CONN="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
elif [[ "$CONN" == *password=* ]]; then
  echo "audit-database: quoted password= in a keyword/value connection string is not supported; use a URI or PGPASSWORD" >&2
  exit 1
fi
[[ -n "${PGPASSWORD:-}" ]] && export PGPASSWORD
SQL_DIR="${AUDIT_SQL_DIR:-/audit/sql}"
FORMAT="${AUDIT_FORMAT:-json}"
ONLY="${AUDIT_ONLY:-}"
SKIP="${AUDIT_SKIP:-}"
WITH_DATA="${AUDIT_WITH_DATA:-0}"
FAIL_ON="${AUDIT_FAIL_ON:-}"

# Tunables, each overridable with `--set name=value` on the host wrapper.
declare -A VARS=(
  [schemas]="${AUDIT_SCHEMAS:-}"
  [max_rows]="${AUDIT_MAX_ROWS:-200}"
  [stmt_timeout]="${AUDIT_TIMEOUT:-60s}"
  [ignore_tables]='^(schema_migrations|ar_internal_metadata|__drizzle_migrations|_prisma_migrations|flyway_schema_history|knex_migrations(_lock)?|django_migrations|alembic_version|typeorm_metadata|migrations|spatial_ref_sys)$'
  [tenant_col]='^(tenant_id|tenantId|organization_id|organisation_id|organizationId|org_id|workspace_id|workspaceId)$'
  [probe_rows]=50000
  [min_rows]=100
  [n1_min_calls]=1000
  [long_tx_seconds]=300
  [dead_min]=1000
  [xid_age_warn]=500000000
  [seq_pct]=50
)
while IFS= read -r kv; do
  [[ "$kv" == *=* ]] || continue
  VARS["${kv%%=*}"]="${kv#*=}"
done <<<"${AUDIT_SETS:-}"

for name in max_rows probe_rows min_rows n1_min_calls long_tx_seconds dead_min xid_age_warn seq_pct; do
  [[ "${VARS[$name]}" =~ ^[0-9]+$ ]] || { echo "audit-database: $name must be an integer" >&2; exit 1; }
done

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s" | tr -d '\000-\037'
}

redact() {
  local s="$1"
  s="${s//"$AUDIT_DB_URL"/<connection string redacted>}"
  local pw="${PGPASSWORD:-}"
  [[ ${#pw} -ge 8 ]] && s="${s//"$pw"/<password redacted>}"
  printf '%s' "$s"
}

meta() { sed -n "s/^-- $1: *//p" "$2" | head -n 1; }

# The session is read-only three times over: the session default, the explicit
# READ ONLY transaction, and a guard that aborts if neither took effect (for
# example behind a pooler that resets session settings).
PRELUDE='\set QUIET on
SET default_transaction_read_only = on;
SET statement_timeout = :'"'"'stmt_timeout'"'"';
SET lock_timeout = '"'"'3s'"'"';
SET application_name = '"'"'audit-database'"'"';
BEGIN TRANSACTION READ ONLY;
DO $guard$ BEGIN
  IF current_setting('"'"'transaction_read_only'"'"') <> '"'"'on'"'"' THEN
    RAISE EXCEPTION '"'"'audit-database: session is not read-only, aborting'"'"';
  END IF;
END $guard$;
'

TAIL_JSON='
), audit_n AS (SELECT count(*) AS n FROM audit_q),
audit_l AS (SELECT object, detail FROM audit_q ORDER BY 1, 2 LIMIT :max_rows)
SELECT n, json_build_object(
  '"'"'id'"'"', :'"'"'audit_id'"'"', '"'"'severity'"'"', :'"'"'audit_severity'"'"', '"'"'category'"'"', :'"'"'audit_category'"'"',
  '"'"'title'"'"', :'"'"'audit_title'"'"', '"'"'status'"'"', '"'"'ok'"'"', '"'"'count'"'"', n, '"'"'truncated'"'"', n > :max_rows,
  '"'"'fix'"'"', :'"'"'audit_fix'"'"',
  '"'"'findings'"'"', coalesce((SELECT json_agg(json_build_object('"'"'object'"'"', object, '"'"'detail'"'"', detail)) FROM audit_l), '"'"'[]'"'"'::json))
FROM audit_n;
ROLLBACK;
'

TAIL_MD='
), audit_n AS (SELECT count(*) AS n FROM audit_q),
audit_l AS (SELECT object, detail FROM audit_q ORDER BY 1, 2 LIMIT :max_rows)
SELECT n, format(E'"'"'### %s %s: %s (%s)\n\n**Fix.** %s\n\n| Object | Detail |\n|---|---|\n%s%s\n'"'"',
  upper(:'"'"'audit_severity'"'"'), :'"'"'audit_id'"'"', :'"'"'audit_title'"'"', n, :'"'"'audit_fix'"'"',
  (SELECT string_agg(format('"'"'| `%s` | %s |'"'"', replace(object, '"'"'|'"'"', '"'"'\|'"'"'),
                            replace(replace(detail, '"'"'|'"'"', '"'"'\|'"'"'), E'"'"'\n'"'"', '"'"' '"'"')), E'"'"'\n'"'"') FROM audit_l),
  CASE WHEN n > :max_rows THEN format(E'"'"'\n\n_%s more rows not shown (raise --max-rows)._'"'"', n - :max_rows) ELSE '"'"''"'"' END)
FROM audit_n;
ROLLBACK;
'

psql_args=(-X -q -A -t -F $'\n' -v ON_ERROR_STOP=1)
for name in "${!VARS[@]}"; do psql_args+=(-v "$name=${VARS[$name]}"); done

# --- connection and context -------------------------------------------------
ctx_err="$(mktemp)"
ctx="$(printf '%s\n' "SELECT current_database(), current_setting('server_version'), current_setting('is_superuser'), pg_has_role(current_user, 'pg_monitor', 'USAGE')::text, coalesce((SELECT string_agg(extname, ',') FROM pg_extension), ''), CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END, coalesce((SELECT CASE WHEN ssl THEN 'encrypted' ELSE 'plaintext' END FROM pg_stat_ssl WHERE pid = pg_backend_pid()), 'unknown');" \
  | psql "$CONN" -X -q -A -t -F $'\n' -v ON_ERROR_STOP=1 2>"$ctx_err")" || {
  echo "audit-database: cannot connect: $(redact "$(tr '\n' ' ' <"$ctx_err")")" >&2
  exit 1
}
{ read -r DB_NAME; read -r SERVER_VERSION; read -r IS_SUPER; read -r IS_MONITOR; read -r EXTENSIONS; read -r NODE; read -r TRANSPORT; } <<<"$ctx"
[[ "$IS_SUPER" == "on" ]] && IS_SUPER=true || IS_SUPER=false
# libpq's default sslmode (prefer) falls back to plaintext and never verifies
# the server. The audit records what its own session got and says so loudly.
if [[ "$TRANSPORT" != "encrypted" ]]; then
  echo "audit-database: WARNING: this session is $TRANSPORT. For a remote database put sslmode=verify-full in the connection string (and --ca-file) before connecting" >&2
fi

declare -A RANK=([critical]=5 [high]=4 [medium]=3 [low]=2 [info]=1)
declare -A FINDINGS=([critical]=0 [high]=0 [medium]=0 [low]=0 [info]=0)
declare -A MD_SECTIONS=([critical]="" [high]="" [medium]="" [low]="" [info]="")
json_lines=()
md_clean=()
md_notrun=()
n_run=0; n_err=0; n_skip=0; worst=0

shopt -s nullglob
files=("$SQL_DIR"/*.sql)
[[ ${#files[@]} -gt 0 ]] || { echo "audit-database: no check found in $SQL_DIR" >&2; exit 1; }

not_run() { # id severity category title status reason
  json_lines+=("{\"id\" : \"$(json_escape "$1")\", \"severity\" : \"$2\", \"category\" : \"$(json_escape "$3")\", \"title\" : \"$(json_escape "$4")\", \"status\" : \"$5\", \"count\" : 0, \"reason\" : \"$(json_escape "$6")\", \"findings\" : []}")
  md_notrun+=("| $1 | $5 | $4 | ${6//|/\\|} |")
  echo "[$1] $5: $6" >&2
}

for file in "${files[@]}"; do
  id="$(meta id "$file")"; severity="$(meta severity "$file")"; category="$(meta category "$file")"
  title="$(meta title "$file")"; fix="$(meta fix "$file")"
  probe="$(meta data-probe "$file")"; needs_ext="$(meta requires-extension "$file")"
  if [[ -z "$id" || -z "${RANK[$severity]:-}" || -z "$title" ]]; then
    echo "audit-database: $file has an invalid header (id, severity, title required)" >&2; exit 1
  fi
  [[ -n "$ONLY" && ! "$id" =~ $ONLY ]] && continue
  [[ -n "$SKIP" && "$id" =~ $SKIP ]] && continue

  if [[ "$probe" == "true" && "$WITH_DATA" != "1" ]]; then
    n_skip=$((n_skip + 1)); not_run "$id" "$severity" "$category" "$title" skipped "reads table rows: re-run with --with-data"; continue
  fi
  if [[ -n "$needs_ext" && ",$EXTENSIONS," != *",$needs_ext,"* ]]; then
    n_skip=$((n_skip + 1)); not_run "$id" "$severity" "$category" "$title" skipped "extension $needs_ext is not installed"; continue
  fi

  [[ "$FORMAT" == "markdown" ]] && tail_sql="$TAIL_MD" || tail_sql="$TAIL_JSON"
  err_file="$(mktemp)"
  if out="$( { printf '%s' "$PRELUDE"; printf 'WITH audit_q AS (\n'; cat "$file"; printf '%s' "$tail_sql"; } \
      | psql "$CONN" "${psql_args[@]}" \
          -v audit_id="$id" -v audit_severity="$severity" -v audit_category="$category" \
          -v audit_title="$title" -v audit_fix="$fix" 2>"$err_file" )"; then
    count="${out%%$'\n'*}"; body="${out#*$'\n'}"
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
      n_err=$((n_err + 1)); not_run "$id" "$severity" "$category" "$title" error "unexpected output from the check"; continue
    fi
    n_run=$((n_run + 1))
    echo "[$id] $count finding(s)" >&2
    if [[ "$count" -gt 0 ]]; then
      FINDINGS[$severity]=$((FINDINGS[$severity] + count))
      [[ ${RANK[$severity]} -gt $worst ]] && worst=${RANK[$severity]}
    fi
    if [[ "$FORMAT" == "markdown" ]]; then
      if [[ "$count" -gt 0 ]]; then MD_SECTIONS[$severity]+="$body"$'\n\n'; else md_clean+=("$id ($title)"); fi
    else
      json_lines+=("$body")
    fi
  else
    n_err=$((n_err + 1))
    reason="$(redact "$(grep -m 1 -E 'ERROR|FATAL' "$err_file" || head -n 1 "$err_file")")"
    not_run "$id" "$severity" "$category" "$title" error "${reason:-psql failed}"
  fi
  rm -f "$err_file"
done

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$FORMAT" == "markdown" ]]; then
  echo "# Database audit: automated findings"
  echo
  echo "- Database: \`$DB_NAME\` (PostgreSQL $SERVER_VERSION, $NODE), generated $generated_at"
  echo "- Statistics, sessions, locks, slots and settings describe this node only ($NODE); they say nothing about the other nodes"
  echo "- Schemas: ${VARS[schemas]:-all non-system schemas}; data probes: $([[ "$WITH_DATA" == "1" ]] && echo on || echo off)"
  echo "- Audit session transport: $TRANSPORT (TLS is verified only when the connection string says sslmode=verify-full)"
  echo "- Audit role: superuser=$IS_SUPER, pg_monitor=$IS_MONITOR (without pg_monitor, statistics-based checks under-report)"
  echo "- Checks: $n_run run, $n_skip skipped, $n_err in error"
  echo
  echo "| Severity | Findings |"
  echo "|---|---|"
  for sev in critical high medium low info; do echo "| $sev | ${FINDINGS[$sev]} |"; done
  echo
  for sev in critical high medium low info; do
    [[ -n "${MD_SECTIONS[$sev]}" ]] && printf '%s' "${MD_SECTIONS[$sev]}"
  done
  if [[ ${#md_clean[@]} -gt 0 ]]; then
    echo "## Checks with no finding"; echo
    for line in "${md_clean[@]}"; do echo "- $line"; done; echo
  fi
  if [[ ${#md_notrun[@]} -gt 0 ]]; then
    echo "## Checks not run (a blind spot, not a pass)"; echo
    echo "| Check | Status | Title | Reason |"; echo "|---|---|---|---|"
    for line in "${md_notrun[@]}"; do echo "$line"; done; echo
  fi
else
  echo "{\"tool\": \"audit-database\", \"format_version\": 1, \"generated_at\": \"$generated_at\","
  echo " \"database\": \"$(json_escape "$DB_NAME")\", \"server_version\": \"$(json_escape "$SERVER_VERSION")\","
  echo " \"node\": \"$NODE\", \"transport\": \"$TRANSPORT\", \"audit_role\": {\"superuser\": $IS_SUPER, \"pg_monitor\": $IS_MONITOR},"
  echo " \"schemas\": \"$(json_escape "${VARS[schemas]}")\", \"data_probes\": $([[ "$WITH_DATA" == "1" ]] && echo true || echo false),"
  echo " \"summary\": {\"findings\": {\"critical\": ${FINDINGS[critical]}, \"high\": ${FINDINGS[high]}, \"medium\": ${FINDINGS[medium]}, \"low\": ${FINDINGS[low]}, \"info\": ${FINDINGS[info]}}, \"checks_run\": $n_run, \"checks_skipped\": $n_skip, \"checks_in_error\": $n_err},"
  echo " \"checks\": ["
  last=$(( ${#json_lines[@]} - 1 ))
  for i in "${!json_lines[@]}"; do
    if [[ "$i" -lt "$last" ]]; then printf '%s,\n' "${json_lines[$i]}"; else printf '%s\n' "${json_lines[$i]}"; fi
  done
  echo " ]}"
fi

if [[ -n "$FAIL_ON" && $worst -ge ${RANK[$FAIL_ON]:-99} ]]; then exit 2; fi
exit 0
