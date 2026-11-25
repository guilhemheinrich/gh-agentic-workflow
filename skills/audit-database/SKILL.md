---
name: audit-database
description: >-
  Audit a relational database (PostgreSQL first, notes for MySQL and SQL
  Server) for relational integrity and for business rules that leaked into the
  ORM: polymorphic associations by convention (entity_id + entity_type with no
  foreign key), missing foreign keys and orphan rows, constraints enforced only
  in code, enums as free text, JSON hiding relations, soft delete, money as
  float, timestamps without time zone, multi-tenant leakage, indexes,
  operations (bloat, sequences, long transactions, backups), migration safety
  and security (roles, grants, RLS, pg_hba, PII). Ships a read-only,
  Docker-only script running 54 catalog checks with JSON or markdown output,
  ORM grep patterns, remediation SQL and a deliverable template. Use when asked
  to audit, review or assess a database or schema, to find polymorphic
  associations or missing foreign keys, to check whether BI/ETL tools can read
  a database without the application, or to explain to a non-specialist what a
  database audit covers.
tags:
  - sql
  - backend
  - architecture
  - quality
  - security
  - docker
  - verification
---

# Audit Database

## What this audit answers (for humans)

(Every term is defined with an example in [references/glossary.md](references/glossary.md).)
One question: **can someone who has only the database, and not the application
code, read it correctly and trust it?** A BI tool, an ETL job, a second service
and a developer hired three years from now are all in that position.

Two families of defects make the answer "no":

1. **Integrity the database does not enforce.** Made-up example: `orders.customer_id`
   holds `4812` but no customer 4812 exists, because no foreign key forbade it.
2. **Meaning that lives only in the ORM.** Real example:
   `scripts/fixtures/fixture-schema.sql:49` declares `commentable_id bigint` next to
   `commentable_type text`. Which table does `commentable_id = 7` point to? Only
   the Rails/Laravel model can say. That is the headline anti-pattern:
   [references/polymorphic-associations.md](references/polymorphic-associations.md).

This skill detects; `skills/sql-migration-guidelines/` and `skills/philosophy-data-first/`
prescribe: read them when drafting a fix. The report must stand alone (its
readers lack this repository): put the SQL in it.

**Language (mandatory).** Everything addressed to the person — the chat
answer, the report, the findings, the plan, the "not verified" list — is written
in **their language**, the one of their request (French request, French report).
Never default to English. Code, commands, SQL, file paths, identifiers, tool
output quoted as evidence and rule ids (`IDX-001`) stay as they are; the prose
around them is translated, and so are headings and severity labels.

## Non-negotiable rules

- **Read-only.** The audit never writes and never runs DDL. Fixes are proposed
  as SQL in the report; the team applies them through its migration process.
- **Authorised target only.** Before the first connection to anything but the
  fixture, the user confirms in the conversation: the exact host and database,
  primary or replica, that they may audit it, and whether data probes
  (`--with-data`) are allowed. Never infer this; holding the credentials is
  not an authorisation. No answer on data probes means catalog-only.
- **Docker-only.** No `psql`, driver or package on the host. The script runs the
  `postgres:16` image, a major-version tag: set `AUDIT_PSQL_IMAGE` to a digest to pin it.
- **Secrets stay in the environment.** The connection string is read from an
  environment variable. Never echo it, never put it on a command line, never
  write it to a file, a report or a commit.
- **Verified TLS to a remote server.** libpq's default falls back to plaintext
  and verifies nothing: the string must say `sslmode=verify-full` (CA through
  `--ca-file`). If that fails, stop and ask; never retry without it.
- **Names and counts, not row contents.** The only row values ever output are
  discriminator values (`'Article'`) and JSON key names; if one could identify
  a person, report the count only. Keep the raw output files internal.
- **Evidence or nothing.** Every finding carries the object name and the query
  (or `file:line`) that proves it. A suspicion goes in "Open questions". A
  check that did not run is a blind spot, not a pass.

## Workflow

### Step 1 - Scope and access

Ask, never infer, and write at the top of the report: the authorisation above,
engine and version, schemas, ORM and where its models and migrations live,
single- or multi-tenant. Then take the first access row you are authorised for:

| Access you have | What you can run | Blind spots to declare |
|---|---|---|
| Read-only role on a **replica**, with `pg_monitor` | Schema checks and data probes | Node-local checks describe the replica, not the primary: `OPS-002..006`, `OPS-008`, `IDX-003`, `SEC-004`, `SEC-005` (which also needs a superuser) |
| Read-only role on the **primary**, with `pg_monitor` | Everything except `SEC-005`. Data probes only with an explicit yes, off-peak, with a stop condition agreed first: `probe_rows` (50 000) caps the sample, not the I/O; each probe may scan a table and its parent for up to 60 s | `SEC-005`; index usage on replicas |
| Read-only role without `pg_monitor` | Catalog checks | Statistics under-report (`IDX-003`, `OPS-002..005`) |
| No `SELECT` on tables (catalog only) | Run without `--with-data` | Data probes (`REL-002`, `REL-003`, `REL-005`, `TYP-004`) and `pg_stats` (`CON-001`, `CON-003`); `ACC-001` lists the objects |
| **Only a schema dump or migrations** | Load it into a throwaway `postgres:16` container on an isolated Docker network, with no credentials or host mounts (a dump is code that runs); `scripts/test-audit.sh` shows how | All `OPS-*`, most `SEC-*`, every data probe and statistic |
| Only the ORM code | Step 4 alone | Everything the database would have proven |

Role to request from the DBA (never create it yourself on a real server):

```sql
CREATE ROLE audit_reader LOGIN;                      -- password set by the DBA
GRANT pg_monitor TO audit_reader;                    -- statistics and settings
GRANT USAGE ON SCHEMA app TO audit_reader;           -- repeat per schema
GRANT SELECT ON ALL SEQUENCES IN SCHEMA app TO audit_reader;  -- OPS-001 is blind without it
GRANT SELECT ON ALL TABLES IN SCHEMA app TO audit_reader;     -- --with-data, pg_stats (CON-001/003)
ALTER ROLE audit_reader SET default_transaction_read_only = on;
```

**Row-level security hides rows from this role too**: a zero is not a pass, and
an "orphan" may be a parent the role cannot see. `ACC-001` lists every object
the role cannot fully read: report them as blind spots. Granting `BYPASSRLS` is
the data owner's decision, not yours.

### Step 2 - Catalog extraction (automated)

```bash
export AUDIT_DATABASE_URL          # value comes from the secret store, never typed inline
skills/audit-database/scripts/audit-schema.sh --list                      # what will run
skills/audit-database/scripts/audit-schema.sh --format json --output audit.json
skills/audit-database/scripts/audit-schema.sh --with-data --format markdown --output audit-findings.md
```

Options (`--help` for all): `--schemas app,billing`, `--only '^REL-|^TEN-'`,
`--skip '^OPS-'`, `--env-var NAME`, `--set long_tx_seconds=60`, `--ca-file PATH`,
`--fail-on high` (exit 2, for CI), `--network host|container:<name>|<network>`
(a database on the host: `host.docker.internal`, or `localhost` with `--network host` on Linux).

Read-only is enforced three times (`scripts/lib/run-checks.sh`): a read-only
session default, `BEGIN TRANSACTION READ ONLY` around every check (with a 60 s
`statement_timeout` and a 3 s `lock_timeout`), and a guard that aborts
otherwise. The self-test proves a check calling `nextval()` is refused, even as
superuser. This blocks data and schema changes; it is not a sandbox, so every
check is a reviewed `SELECT`. Give SQL you run by hand the same guard:
`BEGIN TRANSACTION READ ONLY; SET LOCAL statement_timeout = '60s';` ... `ROLLBACK;`.

Per check, the output gives id, severity, count, findings (`object`, `detail`)
and a one-line fix (one SQL file per check under `scripts/sql/`), plus the node
(primary or replica) and whether the audit session was encrypted. MySQL, SQL
Server: the script does not run; [references/checks-catalog.md](references/checks-catalog.md)
section 10 has porting notes only. List every unported check as **not run**.

### Step 3 - Rule-by-rule review

The script proves facts; you decide what they mean, with
[references/checks-catalog.md](references/checks-catalog.md). Every row the script
returns is a **candidate**. Give each one exactly one outcome:

| What you established | Outcome | Where it goes |
|---|---|---|
| The defect is real | Confirmed | Finding card, scored |
| A "Not a finding when" note applies and you verified it | Dismissed | "Reviewed and dismissed", one line with the reason; not scored |
| Real, but something reduces the damage | Confirmed, one level lower | Finding card, with the reason |
| You cannot tell (no code access, no answer) | Inconclusive | "Open questions" |
| The check was skipped, failed, or saw partial data (`ACC-001`) | Not run | Blind spots |

Review order, most damaging first: polymorphic pairs (`REL-001..003`), missing
references and orphans (`REL-004..011`), `CON-*` and `TYP-*`, tenant isolation
(`TEN-*`), `SEC-*`, operations (`OPS-*`, `IDX-*`), readability (`DOC-*`, `AUD-*`,
`NAM-*`, `DUP-*`), then `MIG-*` (read the last 20 migrations).

Severity is set by the check, then adjusted by you with this rubric:

| Severity | Meaning | Example |
|---|---|---|
| critical | Wrong data exists now, or data is exposed now | `REL-003`: 1 of 3 sampled `Article` comments points at no article |
| high | Nothing prevents wrong data or exposure | `REL-001`: `comments.commentable_id` cannot have a foreign key |
| medium | Correct today only because the application behaves | `AUD-002`: `updated_at` with no trigger |
| low | Costs reading time, performance or clarity | `DOC-001`: table without comment |
| info | Inventory to act on elsewhere | `SEC-007`: columns likely to hold personal data |

Raise one level when the table is large, money- or identity-related, or read by
other systems. Example: `REL-001` is high; with `REL-003` orphans the same card
is critical. Score confirmed findings only.

### Step 4 - ORM and code cross-check

The catalog shows what the database does *not* enforce; the code shows what the
application *believes* is enforced. The gap is the audit's main deliverable.
Grep patterns per ORM: [references/orm-leakage-patterns.md](references/orm-leakage-patterns.md).

| Direction | Start from | Look for | Result |
|---|---|---|---|
| DB -> code | Each `REL-001`, `REL-004`, `CON-001`, `AUD-002`, `TEN-001` finding | The model or relation that gives the column its meaning | Name the file and line; the finding becomes "rule exists only in `<file:line>`" |
| Code -> DB | Each validation, cascade, default, scope, enum, polymorphic relation in the models | The matching constraint in the catalog | Missing constraint = new `ORM-*` finding |

On a large codebase read, in order: the models behind Step 3 findings; money,
identity and tenant tables; the 20 largest tables. The rest is a blind spot: say so.

Then classify every rule you met:

| The rule is found in... | Verdict | Report it as |
|---|---|---|
| Database and code, and they agree (same values, same delete rule, same condition) | Healthy | Not a finding |
| Database and code, but they disagree (model says `dependent: :destroy`, the key says `NO ACTION`) | Mismatch | Finding: name both sides |
| Database only | Healthy | Not a finding |
| Code only, and other writers or readers rely on it (uniqueness, required link, enum, tenant scope) | **ORM leakage** | Finding, with the SQL that moves it into the database |
| Code only, input hygiene (a format, a display length) | Fine in code | Not a finding |
| Neither, yet the domain needs it | Missing invariant | Finding, flagged "to confirm with the domain owner" |

Polymorphic association found? Two remediations are legitimate (details in
[references/polymorphic-associations.md](references/polymorphic-associations.md)):

- **Supertype table** when the set of targets is open, or several tables point
  at the same targets. `skills/sql-migration-guidelines` prefers it (one
  ordinary, typed foreign key) and calls arcs legacy.
- **Exclusive arc** (one foreign-key column per target plus a `CHECK`) when
  there are 2 to 4 stable targets and a single table pointing at them. Where
  that guideline applies, record the arc as an exception or a stepping stone.

### Step 5 - Report

Fill [references/deliverable-template.md](references/deliverable-template.md). Rules:

- Lead with the answer to the opening question, in three plain sentences.
- One card per problem, not per row: 40 tables without comments are one card.
- Every card has: evidence (check id + object, or `file:line`), impact in plain
  words, a fix (runnable SQL for a schema defect; the evidence to request for
  a process defect such as backups), and how to deploy it safely (`NOT VALID`
  now, repair, then `VALIDATE`; `CONCURRENTLY`; `lock_timeout`).
- State the blind spots: checks skipped or in error, `ACC-001` objects, access
  level, node, data probes on or off, statistics age.
- End with a three-horizon plan: stop the bleeding (constraints as `NOT VALID`),
  repair (clean orphans, validate), restructure (replace polymorphic pairs).
  Write it in the person's language (mandatory, see "Language" above); SQL and identifiers stay as is.

## Testing the skill itself

`scripts/test-audit.sh` loads `scripts/fixtures/fixture-schema.sql` (schema
`shop`: one planted defect per check; `clean`: modelled correctly) into a
throwaway container, audits it as superuser and as a least-privilege role, and
asserts every defect is flagged, `clean` is not, and nothing can be written.
Run it after editing `scripts/`; `AUDIT_TEST_SERVER_IMAGE=postgres:13` tests an
older server. Adding a check: see the top of `references/checks-catalog.md`.

## Limits to state honestly

- Name-based detection misses columns named otherwise. Made-up example: `(ref, src)`
  holding `(7, 'invoice')` is caught only by `REL-002` or by reading the model.
- Statistics describe one node since its last reset; `pg_stats` is an
  `ANALYZE` sample. An index unused on the primary may serve a replica.
- Backups and tenant isolation cannot be proven from the catalog: ask for the
  last restore test (`BKP-001`); run `TEN-004`'s seeded two-tenant test, whose
  positive control stops it passing on a table nobody can read.
- The password travels in environment variables, never in a process argument
  list (the self-test checks `docker top`). Host, user and database name do
  appear there, and root on the Docker host can read the environment.
- Tested against PostgreSQL 13, 16 and 17. MySQL and SQL Server: porting notes only.

## References

- [references/polymorphic-associations.md](references/polymorphic-associations.md) - the anti-pattern, detection in SQL and code, four remediations with migration SQL
- [references/checks-catalog.md](references/checks-catalog.md) - every check: id, severity, false positives, fix; `MIG-*`; other engines
- [references/orm-leakage-patterns.md](references/orm-leakage-patterns.md) - grep patterns per ORM, `ORM-*` checks
- [references/deliverable-template.md](references/deliverable-template.md) - the audit report to fill in
- [references/glossary.md](references/glossary.md) - every term, with an example
- [references/review-dispositions.md](references/review-dispositions.md) - adversarial review log: what was accepted, rejected, deferred, and the evidence
