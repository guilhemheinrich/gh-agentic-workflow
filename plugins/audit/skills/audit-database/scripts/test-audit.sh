#!/usr/bin/env bash
# End-to-end self-test of audit-schema.sh. Docker only.
#   1. starts a throwaway postgres:16 container on a private network,
#   2. loads fixtures/fixture-schema.sql (deliberate defects in schema `shop`,
#      a correct model in schema `clean`),
#   3. runs the audit and asserts that every planted defect is flagged, that
#      the clean schema is not, and that the session cannot write,
#   4. removes the container and the network, whatever happened.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Server under test; the audit client image stays the one audit-schema.sh pins.
SERVER_IMAGE="${AUDIT_TEST_SERVER_IMAGE:-postgres:16}"
SUFFIX="$$-$(date +%s)"
NET="audit-db-test-net-$SUFFIX"
PG="audit-db-test-pg-$SUFFIX"
TLS="audit-db-test-tls-$SUFFIX"
OUT="$(mktemp -d)"
fails=0

cleanup() {
  docker rm -f "$PG" "$TLS" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$OUT"
}
trap cleanup EXIT

rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
SUPER_PW="$(rand)"
READER_PW="$(rand)"

ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails + 1)); }

# check_line FILE ID -> the JSON line of that check
check_line() { grep -F "\"id\" : \"$2\"" "$1" || true; }
expect() { # FILE ID SUBSTRING
  if check_line "$1" "$2" | grep -qF -- "$3"; then ok "$2 flags $3"; else fail "$2 should flag: $3"; fi
}
expect_absent() { # FILE ID SUBSTRING
  if check_line "$1" "$2" | grep -qF -- "$3"; then fail "$2 must not mention: $3"; else ok "$2 silent on $3"; fi
}
psql_super() { docker exec -i "$PG" psql -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "== start throwaway PostgreSQL ($SERVER_IMAGE as $PG)"
docker network create "$NET" >/dev/null
POSTGRES_PASSWORD="$SUPER_PW" docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD \
  "$SERVER_IMAGE" -c shared_preload_libraries=pg_stat_statements -c max_prepared_transactions=5 >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$PG" psql -U postgres -h 127.0.0.1 -X -q -c 'SELECT 1' >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "== load fixture"
psql_super <"$HERE/fixtures/fixture-schema.sql" >/dev/null
psql_super -c "ALTER ROLE audit_reader PASSWORD '$READER_PW'" >/dev/null
# A failed CREATE UNIQUE INDEX CONCURRENTLY leaves an invalid index behind (IDX-004).
psql_super -c "INSERT INTO shop.carriers (name) VALUES ('dup'), ('dup')" >/dev/null
docker exec "$PG" psql -U postgres -X -q -c "CREATE UNIQUE INDEX CONCURRENTLY carriers_name_key ON shop.carriers (name)" >/dev/null 2>&1 || true
# N+1 workload: the same point lookup 300 times (OPS-005).
for _ in $(seq 1 300); do echo "SELECT email FROM shop.customers WHERE id = 7;"; done | psql_super >/dev/null
# A transaction left open, and a prepared transaction nobody finished (OPS-003).
docker exec -d "$PG" psql -U postgres -X -q -c "SELECT pg_sleep(600)"
printf '%s\n' "BEGIN;" "SELECT txid_current();" "PREPARE TRANSACTION 'audit_fixture_2pc';" | psql_super >/dev/null
# A role whose password needs percent-encoding in a URI (test literal, not a secret).
psql_super -c "CREATE ROLE audit_pct LOGIN PASSWORD 'p@ss%w:rd/x'" >/dev/null
sleep 3

SUPER_URL="postgresql://postgres:$SUPER_PW@$PG:5432/postgres"
READER_URL="postgresql://audit_reader:$READER_PW@$PG:5432/postgres"
common=(--network "$NET" --set n1_min_calls=200 --set long_tx_seconds=1)

echo "== the fixture line numbers quoted in SKILL.md and references/ still point at the right line"
while read -r line needle; do
  if sed -n "${line}p" "$HERE/fixtures/fixture-schema.sql" | grep -qF -- "$needle"; then ok "fixture line $line holds $needle"; else fail "fixture line $line no longer holds $needle: update the references"; fi
done <<'EOF'
29 created_at
33 PUBLIC
49 commentable_id
57 customer_id
59 status
60 total_amount
61 customer_email
64 deleted_at
67 orders_order_number_key
82 shop.order_items
83 order_id
137 shop.churn
194 product_id
225 clean.comment_targets
227 target_kind
261 num_nonnulls
275 COMMENT ON TABLE
EOF

echo "== run 1: superuser, JSON, with data probes"
J="$OUT/super.json"
AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" "${common[@]}" --with-data --output "$J" 2>"$OUT/super.log" \
  || fail "audit-schema.sh exited $?"

expect "$J" REL-001 'shop.comments (commentable_id, commentable_type)'
expect "$J" REL-002 'shop.comments.commentable_type'
expect "$J" REL-002 'Article -> articles'
expect "$J" REL-003 "commentable_type = 'Article'"
expect "$J" REL-003 '1 of 3 sampled rows are orphans'
expect "$J" REL-003 "commentable_type = 'Ghost'"
expect_absent "$J" REL-003 'Video'
expect "$J" REL-004 'shop.order_items.order_id'
expect "$J" REL-005 '1 of 3 sampled non-null values match no shop.orders.id'
expect "$J" REL-006 'shop.shipments.legacy_ref_id'
expect "$J" REL-007 'shop.order_items'
expect "$J" REL-008 'shop.order_items'
expect "$J" REL-009 'orders_customer_id_fkey'
expect "$J" REL-010 'shop.shipments.order_id'
expect "$J" REL-011 'shipments_carrier_id_fkey'
expect "$J" CON-001 'shop.orders.status'
expect "$J" CON-002 'orders_order_number_key'
expect "$J" CON-002 'coupons_code_is_deleted_key'
expect "$J" CON-002 'deleting a re-created row fails'
expect "$J" CON-002 'orders_number_deleted_key ON shop.orders USING btree (order_number, deleted_at) contains nullable deleted_at'
expect "$J" CON-003 'shop.customers.email'
expect "$J" CON-004 'shop.comments'
expect "$J" CON-005 'shop.orders.status'
expect "$J" TYP-001 'shop.orders.total_amount'
expect "$J" TYP-001 'shop.order_items.unit_price'
expect "$J" TYP-001 'shop.shipments.shipping_fee'
expect "$J" TYP-001 'lc_monetary'
expect "$J" TYP-002 'shop.customers.created_at'
expect "$J" TYP-003 'shop.orders.meta'
expect "$J" TYP-004 'product_id (50)'
expect "$J" DOC-001 'shop.orders'
expect "$J" DOC-002 'shop.orders'
expect "$J" AUD-001 'shop.videos'
expect "$J" AUD-002 'shop.orders.updated_at'
expect "$J" NAM-001 'shop.products.\"Name\"'
expect "$J" IDX-001 'orders_customer_id_fkey'
expect "$J" IDX-002 'products_sku_idx, products_sku_idx2'
expect "$J" IDX-002 'only products_name_ix is droppable; products_name_uq enforces uniqueness and must stay'
expect_absent "$J" IDX-002 'identical indexes: products_name_ix'
if [[ "$(psql_super -tAc "SELECT current_setting('server_version_num')::int >= 150000")" == t ]]; then
  [[ "$(psql_super -tAc "SELECT count(*) FROM pg_index WHERE indrelid = 'shop.labels'::regclass AND indisunique AND NOT indisprimary")" == 2 ]] \
    && ok "fixture shop.labels holds a default and a NULLS NOT DISTINCT unique index" \
    || fail "fixture shop.labels is missing its two unique indexes"
  expect_absent "$J" IDX-002 'labels_code'
fi
expect "$J" IDX-003 'shop.products_sku_idx'
expect "$J" IDX-004 'carriers_name_key'
expect "$J" IDX-005 'shop.products_sku_idx'
expect "$J" DUP-001 'shop.orders.customer_email'
expect "$J" TEN-001 'shop.orders'
expect "$J" TEN-002 'orders_customer_id_fkey'
expect "$J" TEN-003 'customers_email_key'
expect "$J" TEN-004 'shop.invoices'
expect "$J" TEN-004 'default deny'
expect "$J" TEN-004 'permissive policy refunds_debug has USING (true)'
expect_absent "$J" TEN-004 'shop.credits'
expect "$J" TEN-005 'shop.invoice_totals"'
expect_absent "$J" TEN-005 'invoice_totals_safe'
expect "$J" OPS-001 'shop.orders_id_seq'
expect "$J" OPS-001 'set by the sequence itself (AS integer'
expect "$J" OPS-002 'shop.churn'
expect "$J" OPS-003 'transaction open for'
expect "$J" OPS-003 "prepared transaction 'audit_fixture_2pc'"
expect "$J" OPS-008 'replication slot audit_fixture_slot'
expect "$J" OPS-005 'FROM shop.customers WHERE id = $1'
expect "$J" OPS-006 'archive_mode = off'
expect "$J" SEC-001 'role postgres'
expect "$J" SEC-002 'shop.customers'
expect "$J" SEC-003 'owner postgres'
expect "$J" SEC-004 'ssl = off'
expect "$J" SEC-005 'method=trust'
expect "$J" SEC-006 'extension dblink'
expect "$J" SEC-007 'shop.customers.email'
expect "$J" SEC-008 'shop.customers.password'
expect "$J" SEC-009 'shop.customer_count()'

if check_line "$J" ACC-001 | grep -qF '"status" : "ok", "count" : 0,'; then ok "ACC-001 silent for a superuser (it reads everything)"; else fail "ACC-001 should be empty for a superuser"; fi
if grep -qF '"transport": "plaintext"' "$J" && grep -q 'WARNING: this session is plaintext' "$OUT/super.log"; then ok "a plaintext audit session is recorded and warned about"; else fail "plaintext transport not reported"; fi
if grep -qF '"node": "primary"' "$J"; then ok "output names the node (primary)"; else fail "output does not name the node"; fi

echo "== false-positive guard: the clean schema"
for id in REL-001 REL-002 REL-003 REL-004 REL-005 REL-006 REL-007 REL-009 REL-010 CON-001 TYP-001 TYP-002 \
          DOC-001 DOC-002 AUD-001 AUD-002 IDX-001 IDX-002 IDX-005 DUP-001; do
  expect_absent "$J" "$id" 'clean.'
done

echo "== no check in error, document is valid JSON"
if grep -q '"status" : "error"' "$J"; then fail "some checks are in error: $(grep -F '"status" : "error"' "$J" | cut -c1-300 | head -5)"; else ok "no check in error as superuser"; fi
docker cp "$J" "$PG:/tmp/audit.json" >/dev/null
n="$(printf '%s\n' '\set doc `cat /tmp/audit.json`' "SELECT json_array_length((:'doc')::json -> 'checks');" | docker exec -i "$PG" psql -U postgres -X -q -A -t -v ON_ERROR_STOP=1)" || n=""
if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 50 ]]; then ok "valid JSON with $n checks"; else fail "output is not valid JSON (got '$n')"; fi

echo "== secrets never reach the output"
if grep -qF -e "$SUPER_PW" -e "$READER_PW" "$J" "$OUT/super.log"; then fail "a password leaked into the output"; else ok "no password in stdout/stderr"; fi

echo "== remediation: the four patterns of references/polymorphic-associations.md"
if psql_super <"$HERE/fixtures/remediation-polymorphic.sql" >"$OUT/remediation.log" 2>&1; then
  ok "remediation SQL applies: 10 forbidden writes refused, subtype delete removes parent and comments"
else
  fail "remediation SQL failed: $(tail -n 3 "$OUT/remediation.log")"
fi
R="$OUT/fixed.json"
AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" "${common[@]}" --with-data --schemas fixed --only '^REL-00[1-5]$' --output "$R" 2>/dev/null \
  || fail "audit-schema.sh (fixed) exited $?"
for id in REL-001 REL-002 REL-003 REL-004 REL-005; do
  if check_line "$R" "$id" | grep -qF '"status" : "ok", "count" : 0,'; then ok "$id finds nothing in the remediated schema"; else fail "$id still flags the remediated schema: $(check_line "$R" "$id" | cut -c1-400)"; fi
done

echo "== run 2: least-privilege role, markdown"
M="$OUT/reader.md"
AUDIT_DATABASE_URL="$READER_URL" "$HERE/audit-schema.sh" "${common[@]}" --with-data --format markdown --schemas shop --output "$M" 2>"$OUT/reader.log" \
  || fail "audit-schema.sh (reader) exited $?"
if grep -q '^### HIGH REL-001' "$M"; then ok "markdown has the REL-001 section"; else fail "markdown lacks the REL-001 section"; fi
if grep -q 'shop.comments (commentable_id, commentable_type)' "$M"; then ok "markdown lists the polymorphic pair"; else fail "markdown lacks the polymorphic pair"; fi
if grep -q 'clean\.' "$M"; then fail "--schemas shop leaked the clean schema"; else ok "--schemas restricts the scope"; fi
if grep -q 'superuser=false' "$M"; then ok "ran as a non-superuser"; else fail "reader run did not report superuser=false"; fi
# Partial visibility must be reported, never mistaken for a clean result.
if grep -q '^### INFO ACC-001' "$M" && grep -qF '`shop.invoices` | row level security applies to the audit role' "$M"; then ok "ACC-001 reports the RLS table the reader cannot fully read"; else fail "ACC-001 should report shop.invoices for the reader"; fi
if grep -qF '`shop.orders_id_seq` | sequence not readable' "$M"; then ok "ACC-001 reports the sequence hidden from the reader"; else fail "ACC-001 should report shop.orders_id_seq for the reader"; fi

echo "== thresholds: OPS-007 reports both wraparound counters"
X="$OUT/xid.json"
AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" --network "$NET" --only '^OPS-007$' --set xid_age_warn=0 --output "$X" 2>/dev/null || fail "audit-schema.sh (OPS-007) exited $?"
expect "$X" OPS-007 'age(datfrozenxid) = '
expect "$X" OPS-007 'mxid_age(datminmxid) = '

echo "== the password never appears in a process argument list"
AUDIT_SQL_DIR="$HERE/fixtures/slow-probe" AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" --network "$NET" >/dev/null 2>&1 &
slow_pid=$!
argv=""
for _ in $(seq 1 40); do
  cid="$(docker ps -q --filter label=audit-database=1 | head -n 1)"
  if [[ -n "$cid" ]]; then
    argv="$(docker top "$cid" 2>/dev/null | grep psql || true)"
    [[ -n "$argv" ]] && break
  fi
  sleep 0.25
done
wait "$slow_pid" || true
if [[ -z "$argv" ]]; then fail "could not observe the psql process of the audit container"
elif grep -qF "$SUPER_PW" <<<"$argv"; then fail "the password is visible in psql's argument list"
else ok "psql runs with no password in its argument list (docker top)"; fi

echo "== connection forms: percent-encoded password, --network container:<name>"
set +e
AUDIT_DATABASE_URL="postgresql://audit_pct:p%40ss%25w%3Ard%2Fx@$PG:5432/postgres" "$HERE/audit-schema.sh" --network "$NET" --only '^REL-001$' >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "a percent-encoded password is decoded" || fail "percent-encoded password: exit code $rc"
AUDIT_DATABASE_URL="postgresql://postgres:$SUPER_PW@127.0.0.1:5432/postgres" "$HERE/audit-schema.sh" --network "container:$PG" --only '^REL-001$' >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "--network container:<name> works" || fail "--network container:<name>: exit code $rc"
# The fixture server has no TLS: a connection string that demands it must fail, never fall back to plaintext.
AUDIT_DATABASE_URL="$SUPER_URL?sslmode=verify-full" "$HERE/audit-schema.sh" --network "$NET" --only '^REL-001$' >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "sslmode=verify-full refuses a server without TLS (no silent downgrade)" || fail "sslmode=verify-full: exit code $rc"

echo "== verified TLS: sslmode=verify-full with --ca-file"
# A second server with TLS on, its self-signed certificate issued for its container name.
POSTGRES_PASSWORD="$SUPER_PW" docker run -d --name "$TLS" --network "$NET" -e POSTGRES_PASSWORD -e CN="$TLS" \
  --entrypoint bash "$SERVER_IMAGE" -c 'openssl req -new -x509 -days 1 -nodes -subj "/CN=$CN" -addext "subjectAltName=DNS:$CN" \
    -keyout /tmp/server.key -out /tmp/server.crt 2>/dev/null && chown postgres /tmp/server.key && chmod 600 /tmp/server.key \
    && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key' >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$TLS" psql -U postgres -h 127.0.0.1 -X -q -c 'SELECT 1' >/dev/null 2>&1; then break; fi
  sleep 1
done
docker cp "$TLS:/tmp/server.crt" "$OUT/ca.pem" >/dev/null
TLS_URL="postgresql://postgres:$SUPER_PW@$TLS:5432/postgres?sslmode=verify-full"
AUDIT_DATABASE_URL="$TLS_URL" "$HERE/audit-schema.sh" --network "$NET" --ca-file "$OUT/ca.pem" --only '^REL-001$' --output "$OUT/tls.json" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qF '"transport": "encrypted"' "$OUT/tls.json" \
  && ok "verify-full with --ca-file connects and the session is recorded as encrypted" || fail "verify-full with --ca-file: exit code $rc"
AUDIT_DATABASE_URL="$TLS_URL" "$HERE/audit-schema.sh" --network "$NET" --only '^REL-001$' >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "verify-full without the CA refuses the connection" || fail "verify-full without the CA: exit code $rc"
docker rm -f "$TLS" >/dev/null 2>&1 || true
set -e

echo "== read-only enforcement: a check that tries to write is refused"
W="$OUT/write.json"
AUDIT_SQL_DIR="$HERE/fixtures/write-probe" AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" --network "$NET" --output "$W" 2>"$OUT/write.log" || true
if grep -q 'read-only transaction' "$W"; then ok "write attempt rejected by the server (even as superuser)"; else fail "write attempt was not rejected: $(cat "$W")"; fi
seq="$(docker exec "$PG" psql -U postgres -X -q -A -t -c "SELECT last_value FROM shop.orders_id_seq")"
if [[ "$seq" == "1900000000" ]]; then ok "the sequence did not move"; else fail "the write probe advanced the sequence to $seq"; fi

echo "== --fail-on and bad input"
set +e
AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" --network "$NET" --only '^REL-001$' --fail-on high >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "--fail-on high exits 2 on a high finding" || fail "--fail-on exit code was $rc"
AUDIT_DATABASE_URL="$SUPER_URL" "$HERE/audit-schema.sh" --network "$NET" --only '^REL-001$' --schemas clean --fail-on low >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "--fail-on exits 0 on the clean schema" || fail "clean schema exit code was $rc"
env -u AUDIT_DATABASE_URL "$HERE/audit-schema.sh" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "missing env var exits 1" || fail "missing env var exit code was $rc"
BAD_URL="postgresql://postgres:wrong-$SUPER_PW@$PG:5432/postgres"
err="$(AUDIT_DATABASE_URL="$BAD_URL" "$HERE/audit-schema.sh" --network "$NET" 2>&1 >/dev/null)"; rc=$?
if [[ $rc -eq 1 ]] && ! grep -qF "$SUPER_PW" <<<"$err"; then ok "bad password exits 1 without echoing it"; else fail "bad password: rc=$rc"; fi
set -e

if [[ -n "${AUDIT_TEST_KEEP_OUTPUT:-}" ]]; then
  mkdir -p "$AUDIT_TEST_KEEP_OUTPUT" && cp "$J" "$M" "$OUT"/*.log "$AUDIT_TEST_KEEP_OUTPUT"/
fi

echo
if [[ $fails -eq 0 ]]; then echo "ALL CHECKS PASSED"; else echo "$fails ASSERTION(S) FAILED"; exit 1; fi
