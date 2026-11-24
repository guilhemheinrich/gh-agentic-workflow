# Adversarial review dispositions

Three models from other lineages reviewed this skill on 2026-11-24: GPT 6.2
Astra (A), Gemini 4 Neon (G), Kimi K3.1 Pro (K). Their findings are collapsed
into root causes below. Every claim was checked against the files or a live
server before being acted on. "Live" means reproduced in a throwaway
`postgres:16` container loaded with `scripts/fixtures/fixture-schema.sql`
(MySQL claims: `mysql:8`). After the fixes `scripts/test-audit.sh` passes on
PostgreSQL 13, 16 and 17, with 54 checks.

Verdicts: **ACCEPTED** (fixed), **REJECTED** (claim is wrong, evidence given),
**DEFERRED** (valid, not done, reason given).

| # | Root cause | Raised by | Verdict | Evidence / fix |
|---|---|---|---|---|
| 1 | The audit role silently sees less than the checks assume: sequences, `pg_stats`, tables under RLS. A zero was read as a pass | G, A | ACCEPTED | Live as `audit_reader`: `pg_sequences.last_value` is NULL, `pg_stats` returns no row for an RLS or non-readable table, `count(*)` on the RLS table returns 0 with one row present. New check `ACC-001` lists these objects; sequence grant added to the recommended role; RLS paragraph in `SKILL.md` Step 1. Asserted for the reader run |
| 2 | Replica row said "Everything": sessions, locks, statements, archiver, slots and index usage describe one node | K, A | ACCEPTED | Access table rewritten; the runner prints the node (`primary` / `replica`) in both formats; asserted |
| 3 | `pg_hba_file_rules` is readable with `pg_monitor`, so "needs superuser" is wrong | K | REJECTED | Live as a `pg_monitor` member: `ERROR: permission denied for view pg_hba_file_rules`; the reader run reports `SEC-005` in error. The original text was right. Added only: the view shows the file on disk, not the loaded rules |
| 4 | No authorisation gate: environment inferred, data probes on production on an "off-peak" hint | A, G, K | ACCEPTED | New non-negotiable rule "Authorised target only"; default is catalog-only; `probe_rows` (50 000) and the 60 s bound stated; authorisation line in the report template |
| 5 | The connection string was an argument of `psql`, contradicting "never pass it as an argument" | A, G, K | ACCEPTED | Live: `docker top` showed the full URL with its password. `run-checks.sh` now moves the password to `PGPASSWORD`; test asserts no password in `docker top` and that a percent-encoded password still connects. Residual exposure (environment readable by root, `docker inspect`) stated in Limits. Not checked with `ps` on a native Linux host |
| 6 | `host.docker.internal` does not resolve on Linux | G | REJECTED in part | The wrapper already passed `--add-host host.docker.internal:host-gateway` (the reviewer did not have the script). Checking it exposed a real defect: `--network container:<name>` failed with "conflicting options: custom host-to-IP mapping and the network mode". Fixed and asserted; wording now covers `--network host` on Linux |
| 7 | `TEN-004` called zero policies a leak (it is default deny), missed `USING (true)`, and views bypassing RLS were not checked | A, G, K | ACCEPTED | `TEN-004` rewritten: three situations named separately, permissive `USING (true)` detected. New `TEN-005` (view without `security_invoker`). Catalog states what the catalog cannot prove and gives the two-tenant test. Fixtures `shop.refunds`, `shop.invoice_totals` |
| 8 | `AUD-002` accepted "a generic event trigger" | A, G, K | ACCEPTED | Live: `CREATE EVENT TRIGGER ... ON update` fails with "unrecognized event name". Text removed; note added that any `BEFORE UPDATE` trigger satisfies the check, so read its body |
| 9 | The "portable" polymorphic query: syntax error on MySQL, joins the wrong constraint, rewrites inner `_id` | A, G, K | ACCEPTED | All three reproduced (MySQL `ERROR 1064`; a same-named constraint on another table hid a real pair; `sub_id_ref_id` missed). Query rewritten and re-tested on PostgreSQL 16 and MySQL 8. Also confirmed A's point: a `SELECT`-only role sees 0 rows in `information_schema.table_constraints` (owner: 6), now documented. SQL Server remains untested and the text says so |
| 10 | "MySQL / SQL Server equivalents" promised; only porting notes exist. "Foreign keys only on InnoDB" | A, K | ACCEPTED | Reworded as porting guidance; unported checks must be reported "not run"; NDB and MariaDB noted |
| 11 | Supertype remediation: `CREATE TABLE comments` on an existing schema, nullable parent link, direct subtype delete leaves parent and comments | A, K, G | ACCEPTED | Section B rewritten as target shape plus live order. Remediation fixture now has the delete trigger and two new assertions (article without parent refused; deleting an article removes its parent row and comments) |
| 12 | Dropping the old pair when `pg_stat_statements` shows no reader | A, K | ACCEPTED | Step 7 now requires a reader inventory, an observation window, a dependency check, a backup and the data owner's go; statement statistics are supporting evidence only |
| 13 | A type value matching no table was called "unreachable rows" and could be quarantined on a guess | A | ACCEPTED | `REL-003` detail and catalog now say "unknown mapping" until the code (morph map, alias, composite key) explains it; quarantine only after the mapping is complete |
| 14 | `ORM-003` said children survive a non-ORM delete under `NO ACTION`; `REL-004`'s fix defaulted to `CASCADE` | A | ACCEPTED | Live: the parent delete is refused ("violates foreign key constraint"). `ORM-003` now has a three-row table (refused, cascades without callbacks, orphans). `REL-004` example uses `RESTRICT` and says the rule is the owner's decision |
| 15 | Decision rules contradicted each other: `REL-001` critical against the rubric, "lower one level" against "not a finding", every code-only rule a finding, "database and code" always healthy, a grep hit taken as a fact | K, A | ACCEPTED | One outcome table in Step 3 (confirmed, dismissed, lowered, inconclusive, not run). `REL-001` and `ORM-001` default to high, critical with `REL-003` orphans. Step 4 table distinguishes agreement, mismatch and input hygiene. Template gains "Reviewed and dismissed" |
| 16 | "Never row contents" while examples quote discriminator values; raw output treated as harmless | K, A | ACCEPTED | Rule restated: names and counts, with one named exception; count only if a value could identify a person; output files are internal |
| 17 | `ORM-012` called any `set_config` "a good sign" | G | ACCEPTED | Session-scoped `SET` / `set_config(..., false)` behind a pool is now a critical finding, with an example |
| 18 | Grep patterns too broad or blind: `ddl-auto` (matches `validate`), `migrate dev`, TypeORM `cascade: ['insert']`, `findOne`, `.exists()`, Django `blank=False`, Sequelize `timestamps: true`, Drizzle `foreignKey()`, missing `prisma/migrations` | G, A | ACCEPTED | Old and new patterns run against sample lines; patterns tightened in `checks-catalog.md` and `orm-leakage-patterns.md` |
| 19 | Remediation SQL that misleads or locks: `CON-002`, `TEN-002`, `TYP-002`, `REL-003` "never add the key before zero", `ORM-004` preflight, no `lock_timeout` | G, A | ACCEPTED | Live: `UNIQUE (code, deleted_at)` accepts two live duplicates, so `CON-002` now flags that form (fixture + assertion). Live: `timestamp` to `timestamptz` under `SET LOCAL timezone = 'UTC'` keeps the same `relfilenode`; with `USING` it rewrites. `TEN-002` uses a concurrent index and warns about `MATCH SIMPLE`. One header rule covers `lock_timeout`, `CONCURRENTLY`, `NOT VALID` |
| 20 | Catalog wording that overclaims: `REL-010` varchar, `money` called a float, `CON-003` "never NULL", `SEC-004` MD5, statistics age, `SEC-009`, `OPS-007` scale, `SEC-006` examples | G, A, K | ACCEPTED | Each entry corrected; `TYP-001` now emits a separate detail for `money` (fixture + assertion). Glossary gains SECURITY DEFINER and replication slot |
| 21 | `OPS-006` ignores `archive_library` | G, A | REJECTED | `sql/OPS-006-backup-and-pitr.sql` already read `archive_library`; only the catalog sentence omitted it (fixed). The related point that a standby proves nothing about recovery was right: that row now fires only when archiving is also off |
| 22 | Two entries cited a SQL file that belongs to another skill, absent from this one | G | ACCEPTED | Both references removed and replaced by made-up examples |
| 23 | Missing outage checks: inactive slots, prepared transactions, MultiXact age | G, K, A | ACCEPTED | New `OPS-008`; `OPS-003` lists old prepared transactions; `OPS-007` adds `mxid_age`. All three have a fixture and an assertion |
| 24 | Other missing checks: replication lag, connection saturation, per-table freeze age, role timeouts, checksums, logging, server end-of-life, schema drift against the migration table, UUID as text, `char(n)`, case-sensitive unique keys, a data probe for existing cross-tenant links | G, K | DEFERRED | Valid, but each needs its own fixture and the skill must stay readable. The catalog names them as "not covered: ask monitoring"; `TEN-002` gives the manual count query. Candidates for a later version |
| 25 | Step 4 has no scoping rule for a large codebase | G | ACCEPTED | Reading order and blind-spot rule added |
| 26 | Internal skill paths recommended in a client-facing report | G | ACCEPTED | The report must stand alone; sibling skills are for the auditor |
| 27 | "Pinned `postgres:16`" is a moving tag | A, G, K | ACCEPTED | Reworded; `AUDIT_PSQL_IMAGE` accepts a digest. No digest is hard-coded: it would go stale without an update process |
| 28 | "Refuses any change" oversold read-only mode; loading a dump is execution; hand-run SQL had no guard | A | ACCEPTED | Stated as "blocks data and schema changes, not a sandbox"; dump loading restricted to an isolated container; guard given for manual SQL |
| 29 | Automated analysis of policy expressions, of `SECURITY DEFINER` owners and callers, of trigger bodies | A | DEFERRED | Not decidable from the catalog with useful precision. Documented as manual review steps under `TEN-004`, `SEC-009`, `AUD-002` |
| 30 | Exclusive arc against supertype: this skill offered both, `sql-migration-guidelines` calls arcs legacy | brief | ACCEPTED | Both presented as legitimate with a decision rule (few stable targets and one child table: arc; otherwise supertype). The guideline's preference for the supertype is stated in `SKILL.md` and in the reference |

Totals: 25 accepted, 3 rejected (one of them in part, with a real defect fixed
on the way), 2 deferred.

Not settled here:

- `asset-registry.yml` still describes "51 catalog checks"; the skill now ships
  54. The registry was out of scope for this pass and must be synchronised.
- The portable polymorphic query is untested on SQL Server.
- Argument-list exposure was checked with `docker top`, not with `ps` on a
  native Linux host.

## Round 2

Same three reviewers, on the round-1 result, 2026-11-24: GPT 6.2 Astra (A,
REJECT, 7 findings), Gemini 4 Neon (G, ACCEPT-WITH-FIXES, 6), Kimi K3.1 Pro
(K, ACCEPT-WITH-FIXES, 3). Sixteen findings collapse into 13 root causes.
Each claim was reproduced before acting, in throwaway `postgres:13`, `:16` and
`:17` containers (one script, same result on all three unless stated). After
the fixes `scripts/test-audit.sh` passes on PostgreSQL 13, 16 and 17: still 54
catalog checks; the assertion count is given at the end.

| # | Root cause | Raised by | Verdict | Evidence / fix |
|---|---|---|---|---|
| 1 | A view over an RLS table runs with its owner's rights, so ORM-008's "reporting view" hands every tenant's rows to the reporting role; and a view filtering on the tenant itself leaks without `security_barrier` | A, G | ACCEPTED | Live: a role limited by policy to 1 row of 2 reads 2 through a plain view. Live: a cheap `RAISE NOTICE` function in the caller's `WHERE` logged `a-secret` and `b-secret` through a self-filtering view, only `a-secret` with `security_barrier = true` (separate `psql` calls on 13, 16, 17). ORM-008 now sends to `TEN-005` first and creates the view `security_invoker`; `TEN-005` gains the barrier condition and a `Fix` per version. Fixture `shop.invoice_totals_safe` (security_invoker) must stay silent: created on 15+ only, so that negative does not run on 13 |
| 2 | `IDX-002` could recommend dropping a standalone `UNIQUE` index as the "duplicate" of a plain one; uniqueness and NULL semantics were not part of the comparison | A | ACCEPTED | A standalone `CREATE UNIQUE INDEX` has no `pg_constraint` row, so "keep the one backing a constraint" picked wrong. Live (15+): `UNIQUE ... NULLS NOT DISTINCT` refuses two NULLs that a default unique index accepts. The query now groups identical indexes by shape, uniqueness and `indnullsnotdistinct` (read through `to_jsonb` so 13 still parses), and names only the plain index as droppable. Fixtures: `products_name_uq` / `products_name_ix` (negative: the unique one is never droppable) and a default / `NULLS NOT DISTINCT` pair, `shop.labels` (15+ only, appended at the end of the fixture), that must not be called identical. Mutation test: dropping `nnd` from the grouping makes that assertion fail |
| 3 | Supertype pattern: nothing stops a parent row with no subtype, nor re-pointing a subtype at another parent | A | ACCEPTED | Live on the shape without lifecycle triggers: a comment on a bare `comment_targets` row is accepted (1 row), and an `UPDATE articles SET comment_target_id` leaves the old parent stranded (1 bare parent plus 1 stranded). Reference now asks whether a bare parent is valid in the domain; remediation fixture adds a deferred constraint trigger (subtype required at commit) and a trigger refusing reassignment; both writes are among the 10 refused writes asserted |
| 4 | `TEN-004`'s isolation test passes vacuously: with zero policies, "B invisible, insert refused" holds while testing nothing; any unrelated error counted as "refused" | A | ACCEPTED | Live: zero policies, the role sees 0 B rows **and** 0 of its own A rows, and its own-tenant `INSERT` fails with the same "violates row-level security policy" message. Test rewritten: seeded rows for both tenants, positive control first, writes proven on one's own tenant before changing only the tenant (if the own-tenant write fails, even with the RLS message, writes are "not tested"), views included |
| 5 | Transport security was checked after the first connection; libpq's default `sslmode=prefer` falls back to plaintext and verifies nothing | A | ACCEPTED | Non-negotiable rule in `SKILL.md`: `sslmode=verify-full` before the first remote connection, stop on failure, never retry without it. `audit-schema.sh --ca-file` mounts the CA as `PGSSLROOTCERT`. The runner records the session transport and warns when plaintext. Asserted: `verify-full` against a server without TLS exits 1 (no silent downgrade); plaintext session recorded and warned. New in this round: a second fixture server with TLS and a self-signed certificate for its container name; `verify-full` plus `--ca-file` connects and is recorded `encrypted`, `verify-full` without the CA is refused |
| 6 | `probe_rows` (50 000) was presented as a load bound | A | ACCEPTED | It caps the sample, not the I/O: an orphan probe also reads the parent, and MVCC or RLS can make the scan larger. `SKILL.md` access table says so and requires a stop condition agreed before probing a primary |
| 7 | The live-DDL recipe (`CONCURRENTLY`, `NOT VALID`) is refused for partitioned tables and for `UNIQUE` | A | ACCEPTED | Live on 13, 16, 17: "cannot create index on partitioned table concurrently"; "cannot add NOT VALID foreign key on partitioned table"; "UNIQUE constraints cannot be marked NOT VALID". The documented alternative (`ON ONLY` parent index, `CONCURRENTLY` per partition, `ATTACH PARTITION`) leaves the parent index valid. Catalog header branches on `relkind` and constraint type |
| 8 | `TEN-004 (c)` said permissive `USING (true)` lets every row through, ignoring `RESTRICTIVE` policies | G, K | ACCEPTED | Live: `USING (true)` plus a restrictive tenant policy shows 1 row of 2. The check now flags (c) only when the table has no restrictive policy; the catalog asks to read that policy's roles, commands and expression. Fixture `shop.credits` must stay silent (asserted) |
| 9 | `SEC-004` and `SEC-005` are node-local but were missing from the replica blind spots | G, K | ACCEPTED | Both read the connected node's settings, sessions and `pg_hba` file. Added to the replica row of `SKILL.md` and to the report template's scope sentence |
| 10 | `CON-002` grouped a `NOT NULL` boolean flag with `NULLS NOT DISTINCT` as acceptable | G | ACCEPTED | Live: `UNIQUE (code, is_deleted)`: deleting a re-created row fails ("duplicate key value violates unique constraint"). Now flagged as case (c); fixture `shop.coupons`, asserted |
| 11 | The role grant comment said `SELECT` on tables is only for `--with-data`; `pg_stats` needs it too | G | ACCEPTED | Live: a `pg_monitor` member without `SELECT` gets 0 `pg_stats` rows for an analysed table. Comment and access table now name `CON-001` and `CON-003` |
| 12 | `ORM-004`'s duplicate preflight counted NULLs as one duplicate group | G | ACCEPTED | Live: two NULL emails give 1 "duplicate" group, yet the unique index on `lower(email)` builds. Preflight filters `IS NOT NULL` |
| 13 | Three Rails greps missed canonical forms: `foreign_key: false`, `validates_uniqueness_of`, `enum :status,` | K | ACCEPTED (one in part) | Old and new patterns run on sample lines: each old one missed the quoted form, each new one finds it. Divergence: K asked to drop the `grep -v` filter entirely; kept a narrower `grep -vE "foreign_key: *(true\|\{)"`, which surfaces `foreign_key: false` and still hides declared keys |

Totals: 13 accepted (one in part), 0 rejected, 0 deferred. No reviewer claim
in this round failed to reproduce.

Not settled here:

- `SKILL.md` was over its 250-line budget after the fixes; prose was
  tightened to 250 lines, no rule removed.
- The `TEN-005` and `IDX-002` (`NULLS NOT DISTINCT`) negative fixtures need
  PostgreSQL 15+; on 13 the objects are not created, so the `TEN-005`
  absence assertion passes vacuously and the two `shop.labels` ones are skipped.
- Self-test: 139 assertions on PostgreSQL 16 and 17, 137 on 13, all green; 54 catalog checks unchanged.
- `asset-registry.yml` still needs its description synchronised (out of scope).

## Round 3

Termination check, 2026-11-24. Gemini 4 Neon and Kimi K3.1 Pro: ACCEPT, no
finding. GPT 6.2 Astra: ACCEPT-WITH-FIXES, 5 findings, each reproduced on
`postgres:16` before acting (OPS-001 also through the self-test on 13 and 17).

| # | Root cause | Raised by | Verdict | Evidence / fix |
|---|---|---|---|---|
| 1 | `TEN-005`'s fix ("grant `SELECT` on the table") exposes the columns the view hides: RLS filters rows, never columns | A | ACCEPTED | Live: with `security_invoker` and a table-wide grant, the reporting role reads `card_last4` directly; with a column grant on `(tenant, amount)` the view still works and the direct read is "permission denied". Fix now starts from an inventory of what the view hides, keeps view-only access with a policy-bound owner when the view is the boundary, otherwise uses column grants, and verifies both the allowed view read and the denied direct read |
| 2 | The tenant test trusts `current_setting('app.tenant_id')`, which the role can set itself | A | ACCEPTED | Live: the role runs `SET app.tenant_id = 'B'` and reads tenant B's row. `ORM-012` now says transaction scope does not authenticate the value; a caller that can issue SQL makes the filter application-enforced; database isolation needs an identity the caller cannot change. `TEN-004` test gains step 6; glossary RLS entry notes both limits |
| 3 | Supertype migration backfilled before every writer was dual-writing; the generic expand/contract section gave another order | A | ACCEPTED | Live: a row inserted by an old writer after the backfill makes `VALIDATE` of the `NOT NULL` check fail, and once the check exists the old writer fails. Pattern B order is now expand, dual-write all writers (or retire / trigger-cover them), backfill, reconcile (a missed row is a backfill gap, not an orphan), enforce, switch reads; the generic section's steps 2 and 3 say the same |
| 4 | The report's re-run command hard-coded `--with-data` and dropped `--schemas` | A | ACCEPTED | Text in `deliverable-template.md` section 7 contradicted the authorisation recorded in section 3. The command is now copied from the approved run's options; any widening needs a new authorisation |
| 5 | `OPS-001`'s catalog text said the sequence's own maximum is ignored | A | ACCEPTED in part | Live: an `AS integer` sequence feeding a `bigint` column fails with "nextval: reached maximum value of sequence". The SQL already compared against `least(max_value, column range)`, so the defect was in the documentation, not the query. Fixed the catalog, and the detail now names which limit binds and says widening the column alone does not help. New fixture `shop.events_id_seq` (integer sequence at 93%, bigint column), asserted |

Totals: 5 accepted (one in part: the query was right, its description was
wrong), 0 rejected, 0 deferred.

After the fixes: 54 catalog checks; `scripts/test-audit.sh` green with 140
assertions on PostgreSQL 16 and 17, 138 on 13. `SKILL.md` unchanged (250 lines).
