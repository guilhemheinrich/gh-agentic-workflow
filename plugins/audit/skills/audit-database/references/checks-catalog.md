# Checks catalog

Every check the audit knows. Automated checks are one SQL file each under
`scripts/sql/` (run by `scripts/audit-schema.sh`); the file is the query, this
catalog is how to interpret it. Manual checks (`MIG-*`, `BKP-*`, and the
`ORM-*` family in [orm-leakage-patterns.md](orm-leakage-patterns.md)) carry their
query or grep pattern inline.

Format of each entry: **id (default severity) title**, then *Flags* (the exact
condition), *Not a finding when* (verify it, then dismiss the candidate: see
the outcome table in `SKILL.md`, Step 3), *Fix*. "Fixture" names the planted
defect in `scripts/fixtures/fixture-schema.sql` that the self-test asserts.

Four caveats apply to many entries and are not repeated:

- **Name-based checks** assume English `snake_case` or `camelCase` names. On a
  schema that names things otherwise, expect misses, not false alarms.
- **Statistics-based checks** (marked *stats*) describe the node you are
  connected to and need `pg_monitor`. Each source has its own age: cumulative
  counters since `pg_stat_database.stats_reset`; `pg_stat_statements` since its
  own reset, minus evicted entries; `pg_stats` since the last `ANALYZE` of that
  table (a sample, hidden for tables the role cannot read). Unknown age stays
  "unknown" in the report.
- **Every `Fix` is DDL for the team's migration process**, never run by the
  audit. On a live, ordinary table each statement runs with
  `SET lock_timeout = '5s'`, indexes are built `CONCURRENTLY`, foreign keys and
  `CHECK`s are added `NOT VALID` and validated in a later transaction
  (`MIG-001..004`). Three cases where that recipe is refused by the server
  (reproduced on PostgreSQL 13, 16 and 17), so check `pg_class.relkind` first:
  `UNIQUE` cannot be `NOT VALID` on any table (build the index concurrently,
  then `ADD CONSTRAINT ... USING INDEX`); on a **partitioned** table (`relkind
  = 'p'`) `CREATE INDEX CONCURRENTLY` fails ("cannot create index on
  partitioned table concurrently": build it on each partition concurrently,
  create the parent index `ON ONLY`, then `ATTACH PARTITION` each one), and a
  foreign key from a partitioned table cannot be `NOT VALID` (plan a tested
  migration with its own lock budget instead of promising the staged form).
- **`ACC-001` first.** A check is silent on an object the audit role cannot
  read. Read `ACC-001` before trusting any zero.

Tunable thresholds are passed with `--set name=value`; defaults are in
`scripts/lib/run-checks.sh` (`VARS`).

To add a check: one file `scripts/sql/<ID>-<slug>.sql` with the header
(`-- id`, `-- severity`, `-- category`, `-- title`, `-- fix`, `-- data-probe`),
one `SELECT` returning `object` and `detail` with no trailing semicolon, a
planted defect in the fixture, an `expect` line in `scripts/test-audit.sh`,
and an entry here.

## 0. Audit access (`ACC-*`)

**ACC-001 (info) Objects the audit role cannot fully read.**
`sql/ACC-001-audit-role-visibility.sql`.
*Flags:* tables without `SELECT` (or schema `USAGE`), tables where row level
security applies to the audit role, sequences without `SELECT`/`USAGE`.
Verified on PostgreSQL 16: for such a role `pg_sequences.last_value` is NULL
(`OPS-001` silent), `pg_stats` returns no row (`CON-003` silent), and a
`count(*)` on an RLS table with no matching policy returns 0.
*Not a defect of the database:* it is the list of blind spots. A data probe on
a listed table proves nothing: an "orphan" may be a parent hidden by a policy,
and a zero may be hidden children. Report such results as "in this role's
view", or have the DBA run the audit with a role that can read them.
Fixture: `shop.invoices` (RLS) and `shop.orders_id_seq` for `audit_reader`.

## 1. Relational integrity (`REL-*`)

**REL-001 (high; critical once `REL-003` finds orphans) Polymorphic association by convention.**
`sql/REL-001-polymorphic-pair.sql`.
*Flags:* a column ending `_id|Id|_uuid|_key|_ref|_pk` with no foreign key, next
to a column ending `_type|Type|_kind|_class|_model|_table|_entity` with the same
prefix; or Django's `object_id` next to a `content_type_id` foreign key.
*Not a finding when:* append-only audit/event log; the type names an external
system. Details and remediation: [polymorphic-associations.md](polymorphic-associations.md).
Fixture: `shop.comments (commentable_id, commentable_type)`.

**REL-002 (high, data probe) Text column whose values are table or model names.**
`sql/REL-002-discriminator-values-name-tables.sql`.
*Flags:* a text column named like a discriminator whose sampled distinct values
(up to 30, from the first `probe_rows` rows), once namespaces and plurals are
stripped, equal a table name.
*Not a finding when:* the column is part of a foreign key; the named table has
a foreign key back to this one (supertype classifier); the value names the
row's own table (single-table inheritance). These three are excluded by the
query. Still to rule out by hand: a lookup table that documents the mapping.
*Fix:* as REL-001.

**REL-003 (critical, data probe) Orphan rows behind a polymorphic pair.**
`sql/REL-003-polymorphic-orphans.sql`.
*Flags:* per REL-001 pair and per distinct type value, the number of sampled
rows whose id matches no primary key of the table the value names; and type
values that name no table.
*Not a finding when:* the type value is an alias the code maps to a table
(Laravel `morphMap`, a renamed class) or the target has a composite primary
key. Both are reported as "names no table": that means **unknown mapping**,
not "unreachable rows". Resolve it in the code before concluding. Also not a
finding when a table involved is listed by `ACC-001`.
Ids were sampled: the count is a lower bound on tables larger than `probe_rows`.
*Fix:* add the new foreign keys `NOT VALID` at once (new rows are checked from
then on), repair or quarantine the old rows, then `VALIDATE`. A sampled zero
is not proof; a successful `VALIDATE CONSTRAINT` is.

**REL-004 (high) Column named like a reference to an existing table, without a FOREIGN KEY.**
`sql/REL-004-implicit-reference-without-fk.sql`.
*Flags:* `<x>_id` / `<x>Id` with no foreign key, where a table named `x` or
`xs` exists in the same schema.
*Not a finding when:* the column references another *database* or service
whose table merely has the same name; the table is partitioned or
high-volume and the team removed the key on purpose (then it must be written
in a `COMMENT`, and REL-005 must be zero).
*Fix:* two transactions, so the short lock of the first is released before the scan:
```sql
ALTER TABLE order_items ADD CONSTRAINT order_items_order_id_fkey
  FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE RESTRICT NOT VALID;
-- later, once REL-005 orphans are repaired:
ALTER TABLE order_items VALIDATE CONSTRAINT order_items_order_id_fkey;
```
The `ON DELETE` rule is a business decision, not a default: `RESTRICT` refuses
to delete an order that still has lines, `CASCADE` deletes the lines with it
(and does not run ORM callbacks). Ask the owner; never pick `CASCADE` silently.
Fixture: `shop.order_items.order_id`.

**REL-005 (critical, data probe) Orphan rows behind an undeclared reference.**
`sql/REL-005-implicit-reference-orphans.sql`.
*Flags:* for each REL-004 column, sampled non-null values matching no primary
key of the named table.
*Not a finding when:* the name match was a coincidence (see REL-004).
*Fix:* repair or quarantine; then REL-004's fix. Fixture: order 7777.

**REL-006 (medium) Id-like column with no foreign key and no identifiable target.**
`sql/REL-006-id-column-unknown-target.sql`.
*Flags:* `<x>_id` with no foreign key and no table named after `x` anywhere.
*Not a finding when:* external identifier (`stripe_customer_id`,
`request_id`, `trace_id`). Then the fix is a `COMMENT ON COLUMN` naming the
external system.
*Often is:* a self-reference (`parent_id`, `manager_id`) or a renamed table.
Ask the code (Step 4). Fixture: `shop.shipments.legacy_ref_id`.

**REL-007 (high) Table without a PRIMARY KEY.** `sql/REL-007-table-without-primary-key.sql`.
*Not a finding when:* staging/import tables truncated on each load.
*Fix:* add a key; for a join table, the composite of its two foreign keys.

**REL-008 (medium) Isolated table (no foreign key in or out).**
`sql/REL-008-table-without-any-foreign-key.sql`.
*Not a finding when:* genuine standalone tables (settings, feature flags,
job queues such as pg-boss). The detail gives the number of id-like columns:
zero usually means standalone, more means relations kept in code.

**REL-009 (low) Foreign key with `ON DELETE NO ACTION`.** `sql/REL-009-fk-default-delete-rule.sql`.
*Flags:* `confdeltype = 'a'`. The catalog cannot tell a deliberate `NO ACTION`
from the default nobody chose.
*Not a finding when:* the team states that blocking the parent delete is
intended. Raise to medium when the ORM model declares a cascade the database
lacks (`ORM-003`): the two disagree.
*Fix:* recreate the constraint with an explicit rule
(`backend-and-data:sql-migration-guidelines/SKILL.md:28`).

**REL-010 (medium) Foreign key column typed differently from the referenced key.**
`sql/REL-010-fk-type-mismatch.sql`. *Flags:* differing `atttypid` or `atttypmod`.
*Not a finding when:* the child `varchar(n)` is *wider* than the parent key
(harmless: low). A *narrower* child is real: it rejects valid parent keys.
`integer` referencing `bigint` or the reverse is always real: the narrower
side overflows first. Fixture: `shop.shipments.order_id bigint -> orders.id integer`.

**REL-011 (medium) Constraint left `NOT VALID`.** `sql/REL-011-constraint-not-validated.sql`.
*Flags:* `convalidated = false`: new rows are checked, old rows never were.
*Not a finding when:* a migration is in progress this week. Otherwise count the
violating rows and `VALIDATE CONSTRAINT`.

## 2. Constraints enforced only by the application (`CON-*`)

**CON-001 (medium) Enumeration stored as free text.** `sql/CON-001-enum-as-free-text.sql`.
*Flags:* text column named `status|state|type|kind|role|category|level|mode|priority|stage|phase|visibility|gender|currency|locale`
(or ending so) with no `CHECK` and no foreign key. The detail adds the planner's
distinct-value estimate.
*Not a finding when:* the column is genuinely open-ended (`mime_type`, a
user-defined category): many distinct values. *Fix:*
```sql
ALTER TABLE orders ADD CONSTRAINT orders_status_check
  CHECK (status IN ('draft', 'paid', 'shipped', 'cancelled')) NOT VALID;
ALTER TABLE orders VALIDATE CONSTRAINT orders_status_check;
```
Made-up example: a `CHECK (status IN ('draft','paid','void'))` constraint added `NOT VALID`, then validated.

**CON-002 (high) Soft-deleted table with a non-partial UNIQUE index.**
`sql/CON-002-soft-delete-without-partial-unique.sql`.
*Flags:* on a table with `deleted_at|is_deleted|archived_at|...`, a non-partial
unique index that (a) ignores that column: a deleted row blocks re-creation;
or (b) contains it while it is nullable: NULLs are distinct, so two *live*
rows with the same key are both accepted (verified: `UNIQUE (code, deleted_at)`
accepts `('a', NULL)` twice); not flagged with `NULLS NOT DISTINCT`
(PostgreSQL 15+), which closes that hole. (c) contains a `NOT NULL` boolean
flag, as in `UNIQUE (code, is_deleted)`: live duplicates are refused, but only
one deleted row per key can exist, so deleting a re-created row fails
(verified: "duplicate key value violates unique constraint").
*Not a finding when:* uniqueness must hold across deleted rows too (invoice
numbers, legal identifiers): keep it and say so in a `COMMENT`. A partial
index whose predicate does not select live rows is not detected: read it.
*Fix:*
```sql
CREATE UNIQUE INDEX CONCURRENTLY orders_order_number_live_key
  ON orders (order_number) WHERE deleted_at IS NULL;
ALTER TABLE orders DROP CONSTRAINT orders_order_number_key;   -- DROP INDEX CONCURRENTLY if it is a bare index
```
Before the drop: a foreign key cannot reference a partial index, so if another
table references the old constraint (`pg_constraint.conindid`), keep it. On a
copy, test: two live duplicates refused, re-creation after delete accepted,
restore of a deleted row whose key was re-used refused.
Fixture: `scripts/fixtures/fixture-schema.sql:67`, `orders_number_deleted_key` (b),
`coupons_code_is_deleted_key` (c).

**CON-003 (low, stats) Nullable column with no NULL seen by ANALYZE.** `sql/CON-003-nullable-but-never-null.sql`.
*Flags:* `pg_stats.null_frac = 0` on a nullable column of a table with at least
`min_rows` (100) rows. A lead, not a fact: `ANALYZE` samples rows, so a few
NULLs can exist. The `VALIDATE` step of the fix is the proof.
*Not a finding when:* the value is optional by design and simply always filled
so far; statistics are stale (check `last_analyze`). Confirm against the
ORM's presence validations (`ORM-005`): a column that is `required` in code
and nullable in the database is the real finding.
*Fix (no long lock):* `ADD CONSTRAINT c CHECK (col IS NOT NULL) NOT VALID`,
`VALIDATE CONSTRAINT c`, then `ALTER COLUMN col SET NOT NULL` (PostgreSQL 12+
reuses the validated check and skips the scan), then drop the check.

**CON-004 (low) No natural key.** `sql/CON-004-no-natural-key.sql`.
*Flags:* the only unique index is the primary key on one generated column.
*Not a finding when:* rows have no business identity (comments, log lines,
measurements). It is a finding on reference data (two `countries` rows named
"France") and on anything the application de-duplicates by query first.

**CON-005 (low) Status column with no state-machine guard.** `sql/CON-005-status-without-transition-guard.sql`.
*Flags:* `status|state|stage|phase` column on a table with no `UPDATE` trigger
and no multi-column `CHECK` involving it.
*Not a finding when:* every transition is legal, or transitions are recorded
in an append-only history table. Raise to medium for money or legal states
(`paid`, `signed`). *Fix:* at least the cross-column invariants, for example
`CHECK ((status = 'paid') = (paid_at IS NOT NULL))`; for strict ordering a
`BEFORE UPDATE` trigger comparing `OLD.status` and `NEW.status` against an
allowed-transitions table.

## 3. Types (`TYP-*`)

**TYP-001 (high) Money as floating point, or in the `money` type.** `sql/TYP-001-money-as-float.sql`.
*Flags:* two different defects. (a) `real`/`double precision` columns named
like an amount (`amount|price|total|cost|balance|fee|tax|...`): binary floats
cannot represent `0.1`. (b) any `money` column: it is exact, but its scale and
text format follow the server's `lc_monetary` and it stores no currency
(lower to medium when a single currency and locale are guaranteed).
*Not a finding when:* the float is a rate, ratio or statistic that merely has
"rate" or "total" in a non-monetary sense. *Fix:* `numeric(p, s)`, or integer
minor units with a currency column (made-up example: `amount_cents integer`,
`currency char(3)`).
Fixture: `scripts/fixtures/fixture-schema.sql:60` and `shop.shipments.shipping_fee`.

**TYP-002 (medium) `timestamp without time zone`.** `sql/TYP-002-timestamp-without-time-zone.sql`.
*Not a finding when:* the column is a wall-clock time by nature (a shop's
opening hour, a birth date with time). Then a `COMMENT` must say so.
*Fix:* first find the zone the application wrote in. If it is UTC, PostgreSQL
12+ converts without rewriting the table when the session zone is UTC
(verified on 16: same `relfilenode`): `BEGIN; SET LOCAL timezone = 'UTC';
ALTER TABLE t ALTER COLUMN c TYPE timestamptz; COMMIT;`. Any other zone needs
`USING c AT TIME ZONE '<zone>'`, which rewrites the table under
`ACCESS EXCLUSIVE`: on a large table use expand/contract (`MIG-005`) instead.

**TYP-003 (low) JSON columns (inventory).** `sql/TYP-003-json-columns.sql`.
Lists every `json`/`jsonb` column, whether a `CHECK` constrains its shape, and
flags `json` (text storage). Input for TYP-004 and for the code review.

**TYP-004 (high, data probe) JSON carrying keys that look like foreign keys.**
`sql/TYP-004-json-hides-references.sql`.
*Flags:* top-level keys matching `_id|Id|_ids|_uuid` in a 1000-row sample, with
their frequency.
*Not a finding when:* the document is an immutable snapshot of an external
payload (a webhook body kept for replay). Nested keys are not inspected: read
the model. *Fix:* promote to a column with a foreign key; arrays of ids become
a child table. Fixture: `shop.orders.payload -> product_id`.

## 4. Readability and conventions (`DOC-*`, `AUD-*`, `NAM-*`, `DUP-*`)

**DOC-001 (low) Table without COMMENT / DOC-002 (low) Columns without COMMENT.**
`sql/DOC-001-table-without-comment.sql`, `sql/DOC-002-columns-without-comment.sql`.
DOC-002 reports one line per table (`n of m columns`), ignoring `id` and audit
timestamps. *Report as one card* with totals. *Fix:* template
`backend-and-data:sql-migration-guidelines/templates/comments.sql`. Prioritise status
codes, amounts (unit, currency), flags and JSON shapes.

**AUD-001 (low) Missing created_at / updated_at.** `sql/AUD-001-missing-audit-timestamps.sql`.
*Not a finding when:* immutable reference data loaded by migration.

**AUD-002 (medium) `updated_at` with no BEFORE UPDATE trigger.** `sql/AUD-002-updated-at-without-trigger.sql`.
*Flags:* an update-timestamp column on a table with no `BEFORE UPDATE` trigger.
The ORM sets it; a manual `UPDATE`, a bulk job or another service does not.
*Not a finding when:* the table is append-only (rows are never updated). A
trigger on a partitioned parent is already seen by the check. An *event
trigger* is never an answer: it fires on DDL, not on row updates. The check
accepts any `BEFORE UPDATE` trigger, so read its body: an unrelated trigger
hides the finding (verify by updating a row on a copy, never on the audited
database). *Fix:* `backend-and-data:sql-migration-guidelines/templates/updated-at-trigger.sql`.

**NAM-001 (low) Naming inconsistency.** `sql/NAM-001-naming-inconsistency.sql`.
*Flags:* identifiers that need double quotes; tables in the minority
grammatical number of their schema (schemas of 5+ tables, minority at most a third).
*Not a finding when:* uncountable nouns (`staff`, `news`) trip the plural rule.

**DUP-001 (low) Denormalised copy.** `sql/DUP-001-denormalised-copy.sql`.
*Flags:* a child column named `<fk prefix>_<parent column>` with the parent
column's type (`orders.customer_email` vs `customers.email`), on a table with
no trigger.
*Not a finding when:* it is a point-in-time snapshot (the email the invoice
was sent to). Then it should be named and commented as such. Copies with other
names are invisible to this check: grep the code for callbacks that copy
fields (`ORM-010`).

## 5. Indexes (`IDX-*`)

**IDX-001 (medium) Foreign key without a supporting index.** `sql/IDX-001-fk-without-index.sql`.
*Flags:* no valid, non-partial index whose leading columns are the foreign-key
columns (a unique index on a subset of them also counts).
*Not a finding when:* the child table is tiny and the parent is never deleted
or re-keyed; a partial index `WHERE fk IS NOT NULL` exists (sufficient, but
flagged: the check only accepts non-partial indexes). Raise to high on large
children of frequently deleted parents (each parent delete scans the child
under a lock). *Fix:* `CREATE INDEX CONCURRENTLY ON child (fk)`.

**IDX-002 (medium) Duplicate indexes.** `sql/IDX-002-duplicate-indexes.sql`.
*Flags:* two cases, named in the detail. (a) Identical: same table, method,
key and `INCLUDE` columns, operator classes, collations, options, expressions,
predicate **and** the same uniqueness and NULL semantics: keep one. (b) A plain
index with the shape of a `UNIQUE` index: only the plain one is droppable. A
standalone `CREATE UNIQUE INDEX` enforces uniqueness with no `pg_constraint`
row, so "keep the one that backs a constraint" would wrongly drop it.
*Fix:* `DROP INDEX CONCURRENTLY` on the index the detail names, after checking
that nothing depends on it: a constraint (`pg_constraint.conindid`), the
table's replica identity (`pg_index.indisreplident`), a foreign key that
references it. Fixture: `products_sku_idx` / `products_sku_idx2` (a),
`products_name_ix` against `products_name_uq` (b).

**IDX-003 (low, stats) Index never scanned.** `sql/IDX-003-unused-indexes.sql`.
*Flags:* `idx_scan = 0`, excluding unique and constraint-backing indexes.
*Not a finding when:* statistics were reset recently; the index serves a
replica, a monthly job, or exists to make a foreign key cheap (IDX-001).
Never recommend a drop on this evidence alone: recommend a review.

**IDX-004 (medium) Invalid index.** `sql/IDX-004-invalid-index.sql`. Leftover of a
failed `CREATE INDEX CONCURRENTLY`; costs writes, serves no read.
*Not a finding when:* a concurrent build is running right now
(`pg_stat_progress_create_index`).

**IDX-005 (low) Index redundant with a wider one.** `sql/IDX-005-redundant-prefix-index.sql`.
*Flags:* non-unique btree whose columns are a strict prefix of another index.
*Not a finding when:* the narrow index is much smaller and serves a hot
lookup, or the two differ in sort order or operator class.

## 6. Multi-tenancy (`TEN-*`)

Tenant column regex: `tenant_col`, default
`^(tenant_id|tenantId|organization_id|organisation_id|organizationId|org_id|workspace_id|workspaceId)$`.
Override it first if the project names it otherwise (`--set tenant_col='^company_id$'`),
or every TEN check silently passes. Reference model: a `tenant_id` column in every composite key plus an RLS policy on it.

**TEN-001 (medium) Tenant-scoped table without RLS.** `sql/TEN-001-tenant-table-without-rls.sql`.
*Not a finding when:* isolation is by schema or database per tenant, or the
team consciously isolates in the application. Then record the decision and
raise `ORM-012` if the filter is a default scope that raw SQL bypasses.

**TEN-002 (high) Foreign key between tenant-scoped tables that omits the tenant column.**
`sql/TEN-002-cross-tenant-foreign-key.sql`.
*Flags:* child and parent both carry the tenant column, the key does not.
Nothing stops an order of tenant A from referencing a customer of tenant B.
*Not a finding when:* the parent is shared reference data that happens to
carry a nullable tenant column. *Fix:* composite key, built without blocking writes:
```sql
CREATE UNIQUE INDEX CONCURRENTLY customers_tenant_id_id_key ON customers (tenant_id, id);
ALTER TABLE customers ADD CONSTRAINT customers_tenant_id_id_key
  UNIQUE USING INDEX customers_tenant_id_id_key;
ALTER TABLE orders ADD CONSTRAINT orders_tenant_customer_fkey
  FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id) NOT VALID;
-- later: ALTER TABLE orders VALIDATE CONSTRAINT orders_tenant_customer_fkey;
```
The child's `tenant_id` must be `NOT NULL`: with the default `MATCH SIMPLE`, a
row with a NULL tenant skips the check entirely. Existing cross-tenant links
are not counted by the script; count them by hand before `VALIDATE`:
`SELECT count(*) FROM orders o JOIN customers c ON c.id = o.customer_id WHERE c.tenant_id <> o.tenant_id;`

**TEN-003 (low) UNIQUE index that ignores the tenant column.** `sql/TEN-003-unique-ignoring-tenant.sql`.
*Not a finding when:* global uniqueness is intended (login email across the
platform). Otherwise tenant B learns that tenant A already uses a value.

**TEN-004 (high) RLS enabled but not protecting.** `sql/TEN-004-rls-enabled-but-ineffective.sql`.
*Flags:* three different situations, named in the detail:
(a) zero policies: default **deny** for every role subject to RLS. That is an
availability problem (the application reads nothing), not a leak; the leak is
that the owner and `BYPASSRLS` roles read everything. (b) not `FORCE`d: the
owner is exempt, a leak only if the application connects as the owner
(`FORCE` never constrains superusers or `BYPASSRLS` roles). (c) a permissive
policy with `USING (true)` on a table that has no `RESTRICTIVE` policy:
permissive policies are OR-ed, so every row passes and the others are redundant.
*Not a finding when:* (b) alone and the application role is not the owner
(lower to low); (c) and the policy is `TO` a maintenance role only.
*Not flagged, by design:* permissive `USING (true)` plus a `RESTRICTIVE` tenant
policy. Restrictive policies are AND-ed with the permissive result, so the
tenant filter still applies (verified: 1 of 2 rows visible). Read the
restrictive policy: its roles, its commands and its expression must cover the
application role.
*Not detected:* a policy that is wrong without being literally `true`, the
`WITH CHECK` side, a pooled connection that keeps the previous tenant's
setting (`ORM-012`). The catalog cannot prove isolation; a test does, but
only if it cannot pass by accident. With zero policies a role reads nothing
and inserts nothing, so "B is invisible, insert refused" passes while testing
nothing. On a copy, as the application role:

1. Seed one known row for tenant A and one for tenant B.
2. As A: A's row is visible (**positive control**), B's row is not.
3. As B: the mirror image.
4. Writes: an `INSERT` for one's own tenant succeeds (if it fails, even with
   the RLS message, stop: writes are "not tested"); the same statement with
   only the tenant changed fails with "new row violates row-level security
   policy". Any other error (`NOT NULL`, foreign key) proves nothing.
5. Repeat step 2 through every view granted to that role (`TEN-005`).
6. If the policy reads a setting (`current_setting('app.tenant_id')`), try to
   change it as that role. If it can, and anyone other than the application
   can log in as that role, report isolation as application-enforced (`ORM-012`).

An operation that was not exercised is "not tested", never "isolated".
Fixture: `shop.invoices` (a, b), `shop.refunds` policy `refunds_debug` (c);
`shop.credits` (permissive plus restrictive) must stay silent.

**TEN-005 (high) View over an RLS table running with its owner's rights.**
`sql/TEN-005-view-bypasses-rls.sql`.
*Flags:* a view that reads a table with RLS and is not `security_invoker`
(PostgreSQL 15+; before 15 every view runs as its owner). Rows are then
filtered by the policies that apply to the *view owner*: none if that owner
is the table owner (without `FORCE`), a superuser or a `BYPASSRLS` role.
Verified: with a policy limiting a role to 1 row of 2, the same role reads 2
rows through such a view.
*Not a finding when:* its owner is a role subject to the right policies; or
the view filters on the tenant itself **and** is `security_barrier`. Without
the barrier a caller's cheap function in a `WHERE` runs before the view's
filter and sees the other tenants' rows (verified: it logged both rows; with
`security_barrier = true`, only one).
*Fix:* first list what the view hides (columns, aggregated detail): RLS
filters rows, never columns, so a table-wide `SELECT` grant hands callers
every column of their visible rows (verified: `card_last4` readable directly).
If the view is the access boundary, keep callers on the view only and give it
an owner that is subject to the policies (not the table owner, not
`BYPASSRLS`). Otherwise, PostgreSQL 15+:
`ALTER VIEW app.invoice_totals SET (security_invoker = true);` plus a column
grant limited to what the view reads (`GRANT SELECT (tenant_id, amount) ON app.invoices TO reporting;`).
Before 15, a self-filtering view also needs
`ALTER VIEW app.invoice_totals SET (security_barrier = true);`. Verify both
sides as the caller: the view read works, the direct read of a hidden column
is refused ("permission denied"). The tenant itself must be bound as in
`ORM-012`: a setting the caller can change proves nothing.
Fixture: `shop.invoice_totals`.

## 7. Operations (`OPS-*`)

**OPS-001 (high) Sequence past `seq_pct` (50) percent of its binding limit.**
`sql/OPS-001-sequence-near-overflow.sql`. Compares `last_value` (ascending
sequences) to the lesser of the sequence's own `max_value` and its column's
type range, and names which one binds. An `AS integer` sequence feeding a
`bigint` column stops at 2 147 483 647 (verified: "nextval: reached maximum
value of sequence"). *Not a finding when:* the table is append-rarely and
growth is flat (compute the daily rate from two audits). *Fix:* migrate the
column to `bigint`, foreign key columns included; when the sequence binds,
also `ALTER SEQUENCE ... AS bigint`. Fixtures: `shop.orders_id_seq` (column
binds, 88%), `shop.events_id_seq` (sequence binds, 93%).

**OPS-002 (medium, stats) Dead tuples / autovacuum disabled.** `sql/OPS-002-dead-tuples-and-autovacuum.sql`.
*Flags:* at least `dead_min` (1000) dead tuples and 20% dead; or
`autovacuum_enabled = off`. An estimate from counters, not a measurement.
*Not a finding when:* a large delete just ran and autovacuum is catching up.
Precise bloat needs the `pgstattuple` extension (ask the DBA; do not install).

**OPS-003 (medium, stats) Long transaction.** `sql/OPS-003-long-transactions.sql`.
Sessions whose transaction is older than `long_tx_seconds` (300). Reports pid,
application, state, age, role. Never the query text.
Also lists prepared transactions (`pg_prepared_xacts`) older than the same
threshold: a forgotten `PREPARE TRANSACTION` keeps its locks and holds back
VACUUM until someone commits or rolls it back.
*Not a finding when:* it is a backup (`pg_dump`) or a known batch window.
`idle in transaction` is always a finding: the application holds a transaction
while doing something else (see `backend-and-data:philosophy-data-first`, principle
"no external I/O inside a transaction").

**OPS-004 (medium, stats) Blocked session.** `sql/OPS-004-blocked-sessions.sql`. A
snapshot; empty most of the time. Evidence only if it reproduces.

**OPS-005 (low, stats) N+1 hint.** `sql/OPS-005-n-plus-one-hints.sql`. Needs
`pg_stat_statements`. *Flags:* single-table `SELECT ... WHERE col = $n`
executed at least `n1_min_calls` (1000) times, returning at most 1.5 rows per call.
*Not a finding when:* it is a legitimate hot path (session lookup per request).
It becomes a finding when calls are a large multiple of the request count:
find the loop in the code (`ORM` lazy loading).

**OPS-006 (high) No evidence of WAL archiving / PITR.** `sql/OPS-006-backup-and-pitr.sql`.
*Flags:* `wal_level = minimal`; `archive_mode = off`; archiving on with neither
`archive_command` nor `archive_library` (PostgreSQL 15+) visible; a failing
archiver; archiving off *and* no standby connected. A standby is not a backup
and proves nothing about point-in-time recovery; it is only mentioned as the
last visible second copy of the WAL. On a replica, this describes the replica.
*Not a finding when:* managed service (RDS, Cloud SQL, Azure) or a
backup tool that streams WAL: their configuration is not visible here. This
check can only report *absence of evidence*; pair it with BKP-001.

**OPS-007 (high) Transaction ID or MultiXact ID age.** `sql/OPS-007-transaction-id-age.sql`.
`age(datfrozenxid)` or `mxid_age(datminmxid)` above `xid_age_warn` (500
million). Scale: autovacuum forces a freeze at 200 million (400 million for
MultiXacts) by default; PostgreSQL stops accepting writes near 2 billion. So
500 million means freezing has been failing for a while. Look for what holds
it back: `OPS-003` (long and prepared transactions) and `OPS-008` (slots).

**OPS-008 (high) Replication slot inactive or losing its WAL.** `sql/OPS-008-replication-slots.sql`.
*Flags:* a non-temporary slot with `active = false`, or `wal_status` of
`unreserved` / `lost`. The server keeps every WAL segment an inactive slot has
not consumed: the disk fills, then PostgreSQL stops.
*Not a finding when:* the consumer is restarting right now (re-run), or it is
a logical slot of a batch consumer that connects on a schedule. Dropping a
slot is the DBA's decision. Fixture: `audit_fixture_slot`.

*Not covered by the script (ask the team's monitoring):* replication lag,
connection count against `max_connections`, per-role timeouts, checksum and
logging settings, server end-of-life.

**BKP-001 (manual, high) Restore was never tested.** Ask for: the backup tool
and schedule, retention, the date and duration of the last successful restore
into a scratch environment, the recovery point and time objectives. No date
of a tested restore = finding, whatever OPS-006 says.

## 8. Security (`SEC-*`)

**SEC-001 (medium) Login roles with elevated attributes.** `sql/SEC-001-privileged-login-roles.sql`.
Inventory of login roles that are `SUPERUSER`, `BYPASSRLS`, `CREATEROLE`,
`CREATEDB`, `REPLICATION` or members of file/program access roles. Expected:
the DBA role only. Raise to critical if the application's own role is listed.

**SEC-002 (high) Privileges granted to PUBLIC.** `sql/SEC-002-public-privileges.sql`.
`CREATE` on a schema, or any table privilege, held by PUBLIC.
*Not a finding when:* a deliberately public reference table in a database
with no untrusted roles.

**SEC-003 (medium) Tables owned by a login role.** `sql/SEC-003-tables-owned-by-login-role.sql`.
*Not a finding when:* that role is used only by migrations. Find out which
role the application uses (its connection configuration, not the audit's).

**SEC-004 (high) Unencrypted transport or MD5 password setting.** `sql/SEC-004-transport-encryption.sql`.
*Flags:* `ssl = off`; `password_encryption = md5`; sessions visible to this
role that are not encrypted. Limits: `ssl = on` only makes TLS *possible*
(whether it is required is `SEC-005`); `password_encryption` governs *new*
passwords, so passwords set earlier may still be MD5 whatever it says. Stored
hashes are readable by superusers only and the audit never reads them: ask
the DBA to attest. Node-local, like `SEC-005`: a clean replica says nothing
about the primary's TLS setting, sessions or `pg_hba` rules. The audit's own
session is a separate matter, settled *before* connecting (`SKILL.md`,
"Verified TLS"); the output records whether it was encrypted.
*Not a finding when:* TLS terminates in a sidecar or proxy on the same host
(then `ssl = off` is expected; verify the proxy).

**SEC-005 (high) Weak `pg_hba.conf` rules.** `sql/SEC-005-pg-hba-weak-rules.sql`.
Needs superuser, or an explicit `GRANT SELECT ON pg_hba_file_rules`; `pg_monitor`
is not enough (verified on PostgreSQL 16: "permission denied for view
pg_hba_file_rules"). Otherwise the check ends in error: report it as a blind
spot. The view reads the file on disk, which may differ from the rules loaded
at the last reload. *Not a finding when:* `trust`/`peer` on the local Unix socket of a
single-purpose host; managed services do not expose the file.

**SEC-006 (info) Extensions.** `sql/SEC-006-extensions-inventory.sql`. Flags those
reaching the network, filesystem or OS (`dblink`, `postgres_fdw`, `file_fdw`,
and untrusted languages such as `plpython3u` or `plperlu`, whose functions can
run any command as the database server's OS user).

**SEC-007 (info) Personal-data columns inventory.** `sql/SEC-007-pii-inventory.sql`.
By column name (contact, identity, government id, financial, location, online
identifier, special categories). A starting list, not a register: JSON
documents and free-text columns hide more. Never sample the values.

**SEC-008 (medium) Credential-like column in plain text type.** `sql/SEC-008-credential-columns.sql`.
*Not a finding when:* the code hashes it (then rename it `password_hash`).
Verify in code; do not read the column.

**SEC-009 (medium) SECURITY DEFINER function without `search_path`.**
`sql/SEC-009-security-definer-search-path.sql`. Extension-owned functions excluded.
Such a function runs with its owner's rights. Without a pinned `search_path`,
a caller who can create objects (in `public`, or a temporary table) can make
the function resolve `customers` to *their* object and so run code as the
owner. *Fix:* `ALTER FUNCTION f() SET search_path = app, pg_temp` (trusted
schemas first, `pg_temp` last) and schema-qualify names. A pinned path is
necessary, not sufficient: also check who may `EXECUTE` it (PUBLIC by
default) and who may `CREATE` in the schemas on the path (`SEC-002`).

## 9. Migration safety (`MIG-*`, manual)

Read the 20 most recent migrations and the migration tool's configuration.
The catalog only shows the scars (IDX-004, REL-011). Paths below are the usual
ones; adapt.

```bash
# MIG-001 DDL with no lock_timeout: one blocked ALTER queues every query behind it
grep -rnE "lock_timeout|statement_timeout" db/migrate migrations prisma/migrations drizzle
# MIG-002 NOT NULL added in one step (full scan under ACCESS EXCLUSIVE; fails on existing NULLs)
# Keep only the hits that ALTER an existing table: a NOT NULL column inside CREATE TABLE is fine.
grep -rnEi "add column .* not null|set not null|change_column_null|add_column.*null: *false" db/migrate migrations prisma/migrations drizzle
# MIG-003 index built without CONCURRENTLY (blocks writes for the whole build)
grep -rnEi "create (unique )?index" migrations prisma/migrations drizzle | grep -vi concurrently
grep -rnE "add_index|addIndex|\.index\(" db/migrate migrations | grep -vE "algorithm: *:concurrently|concurrently"
# MIG-004 foreign key or CHECK added without NOT VALID (scans and locks both tables)
grep -rnEi "add constraint .* (foreign key|check)" migrations prisma/migrations drizzle | grep -vi "not valid"
# MIG-005 column type change or rename done in place (table rewrite, or breaks running code)
grep -rnEi "alter column .* type|rename (column|to)|change_column|rename_column|renameColumn" db/migrate migrations prisma/migrations drizzle
# MIG-006 schema managed by auto-sync instead of reviewed migrations (ddl-auto validate/none is safe and not matched)
grep -rnE "synchronize: *true|(hbm2ddl\.auto|ddl-auto) *[:=] *(update|create)|sync\(\{ *(alter|force)|prisma db push" --include='*.ts' --include='*.js' --include='*.yml' --include='*.yaml' --include='*.properties' --include='*.json' --include='Dockerfile*' .
# MIG-007 data backfill inside a schema migration (long transaction holding DDL locks)
grep -rnEi "^\s*(update|insert into|delete from) " migrations prisma/migrations drizzle
```

| Id | Severity | Finding when | Safe form |
|---|---|---|---|
| MIG-001 | medium | No migration sets `lock_timeout` and the tool does not either | `SET lock_timeout = '5s'` at the top; retry on failure |
| MIG-002 | high on large tables | `SET NOT NULL` / `ADD COLUMN ... NOT NULL` with no default on a populated table | See CON-003's fix. `ADD COLUMN ... DEFAULT const` is cheap since PostgreSQL 11 |
| MIG-003 | high on large tables | Plain `CREATE INDEX` on a table that takes writes | `CREATE INDEX CONCURRENTLY`, outside a transaction (Rails: `disable_ddl_transaction!`) |
| MIG-004 | medium | Constraint added and validated in one statement | `NOT VALID`, then `VALIDATE CONSTRAINT` |
| MIG-005 | high | In-place type change or rename while old code still runs | Expand/contract: add new column, dual-write, backfill, switch, drop |
| MIG-006 | critical in production | The setting is active in the production configuration (a hit in a dev-only profile or script is not a finding) | Reviewed SQL migrations only (`backend-and-data:sql-migration-guidelines`) |
| MIG-007 | medium | Large `UPDATE` in the same transaction as DDL | Backfill in batches, in its own migration or job |

*Not a finding when:* the table was empty or tiny at the time, or the project
has an agreed maintenance window. Say which.

## 10. Other engines

The script is PostgreSQL-only. The checks transfer; the queries and some
conclusions do not. This table is porting guidance, not a set of ready
queries: write and test each query on the target engine, and report every
check you did not port as "not run". MariaDB differs from MySQL in places
(`CHECK` is enforced from MariaDB 10.2.1): check the exact engine and version.

| Topic | MySQL / MariaDB | SQL Server |
|---|---|---|
| Catalog | `information_schema` (`columns`, `key_column_usage`, `referential_constraints`, `statistics`) | `sys.tables`, `sys.columns`, `sys.foreign_keys`, `sys.indexes` |
| REL-004 missing FK | Foreign keys are enforced by InnoDB (and NDB); MyISAM tables have none, ever | Same check; also `sys.foreign_keys.is_disabled` |
| REL-011 unvalidated | `SET foreign_key_checks = 0` during loads leaves unchecked rows with no catalog trace: only the orphan query proves it | `sys.foreign_keys.is_not_trusted = 1`, `sys.check_constraints.is_not_trusted` |
| IDX-001 FK index | Not applicable: InnoDB creates the index with the key | Applicable: no automatic index |
| CON-001 CHECK | Enforced only from MySQL 8.0.16 (parsed and ignored before); `ENUM` type is common | `CHECK` works; no enum type |
| CON-002 partial unique | No partial index: use a generated column (`live_key` = value when not deleted) with a unique index | Filtered index: `CREATE UNIQUE INDEX ... WHERE deleted_at IS NULL` |
| TYP-002 time zones | `DATETIME` has no zone; `TIMESTAMP` is UTC-converted but ends in 2038 | `datetime`/`datetime2` have no zone; use `datetimeoffset` |
| TYP-001 money | `FLOAT`/`DOUBLE`; use `DECIMAL` | `float`/`real`; `money` has rounding traps; use `decimal` |
| Exclusive-arc CHECK | `(a IS NOT NULL) + (b IS NOT NULL) = 1` | Sum of `CASE WHEN a IS NOT NULL THEN 1 ELSE 0 END` |
| TEN-001 RLS | None: views or application only | Security policies with predicate functions |
| IDX-003 unused | `sys.schema_unused_indexes` | `sys.dm_db_index_usage_stats` (reset at restart) |
| OPS-005 N+1 | `performance_schema.events_statements_summary_by_digest` | Query Store, `sys.dm_exec_query_stats` |
| MIG safe DDL | No transactional DDL (implicit commit); use `ALGORITHM=INPLACE, LOCK=NONE` or an online schema-change tool | `WITH (ONLINE = ON)` depends on edition |
| Also check | `sql_mode` lacks `STRICT_TRANS_TABLES` (silent truncation), `utf8` (3-byte) instead of `utf8mb4` | Implicit conversions on mismatched key types; `NOLOCK` hints in code |

Orphan detection is the same `NOT EXISTS` query on every engine, and a
polymorphic-pair query tested on PostgreSQL 16 and MySQL 8 is in
[polymorphic-associations.md](polymorphic-associations.md).
