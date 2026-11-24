# Deliverable template (the audit report)

Copy the structure below. Write it in the language of the person who asked
for the audit; keep SQL, identifiers, check ids and file paths verbatim.
Replace every `<...>`. Delete sections that are empty rather than leaving
placeholders. The example cards use the fixture
(`scripts/fixtures/fixture-schema.sql`) so you can see the expected level of
detail; the "made-up" marks show where a real audit must cite real evidence.

Rules that keep the document honest:

- A finding = evidence + impact + fix. No evidence, no finding.
- Counts and names, never row contents. One exception: discriminator values
  and JSON key names (`'Article'`, `product_id`) may be quoted when they are
  schema-like; if a value could identify a person, give the count only. No
  personal data, no secrets, no connection details beyond database name and
  server version.
- One card per problem. Twelve tables without comments are one card.
- Say what was not checked. A reader must not mistake a blind spot for a pass.
- Separate what the database proves (`REL-*`, `CON-*`...) from what the code
  shows (`ORM-*`, `MIG-*`) from what someone told you (mark it "stated by <role>").

---

````markdown
# Database audit: <system name>

<date> · <auditor> · database `<name>`, PostgreSQL <version> · schemas: <list>

## 1. Verdict

<Three sentences, no jargon. Answer: can someone holding only the database
read it correctly and trust it? What is the single most important problem?
What is the first thing to do?>

Example (fixture): The `shop` database cannot be read without its
application: comments are linked to articles and videos by a convention only
the code knows, and one of the three sampled comments on articles already
points at an article that does not exist. Money is stored in a type that cannot represent cents
exactly, and nothing in the database separates one customer organisation's
data from another's. Start by adding the missing foreign keys as `NOT VALID`
so that no new broken link can be created while the existing ones are repaired.

## 2. Scorecard

| Area | Critical | High | Medium | Low | Assessment in one line |
|---|---|---|---|---|---|
| Relational integrity | <n> | <n> | <n> | <n> | <...> |
| Constraints and types | | | | | |
| ORM leakage | | | | | |
| Multi-tenancy | | | | | |
| Security | | | | | |
| Operations and indexes | | | | | |
| Readability | | | | | |
| Migration safety | | | | | |

Counts are confirmed findings (cards), not rows. Dismissed candidates and
blind spots are not counted here.

## 3. Scope and method

- Authorised by <name, role> on <date> for <host and database>; data probes: <allowed / not allowed>.
- Access: <replica / primary>, role `<name>` (superuser: <yes/no>, pg_monitor: <yes/no>).
  Node-local results (`OPS-*`, `IDX-003`, `SEC-004`, `SEC-005`) describe that node
  only; the other nodes are <checked separately / not checked>.
- Audit session: <encrypted with `sslmode=verify-full` / local fixture / other, approved by ...>.
- Automated: `audit-schema.sh` <with / without> `--with-data`, <n> checks run,
  <n> skipped, <n> in error. Raw output: `<path to audit.json>`.
- Code reviewed: `<repo>` at commit `<sha>`, ORM <name and version>, models in
  `<path>`, migrations in `<path>`.
- Statistics: counters since <stats_reset date>; `pg_stat_statements` since
  <its reset, or unknown>; `pg_stats` as of the last `ANALYZE`.

### Not checked (blind spots)

| What | Why | How to close it |
|---|---|---|
| `pg_hba.conf` rules (SEC-005) | Needs superuser | DBA runs `scripts/sql/SEC-005-pg-hba-weak-rules.sql` |
| <n> tables under row level security (ACC-001) | The audit role sees only the rows its policies allow | DBA re-runs the data probes with a role allowed to read them |
| Tenant isolation | Policies were read, not exercised | Two-tenant read and write test as the application role, on a copy (TEN-004) |
| Backups | Not provable from inside the database | Provide the date of the last tested restore (BKP-001) |
| <...> | | |

## 4. Findings

Ordered by severity, then by the order of the checks catalog.

### F-01 · critical · REL-001, REL-003, ORM-001 · Comments are attached by a convention the database cannot check

**Evidence**
- `REL-001`: `shop.comments (commentable_id, commentable_type)`: no foreign key.
- `REL-003`: 1 of 3 sampled rows with `commentable_type = 'Article'` match no
  `shop.articles.id`; the value `'Ghost'` names no table.
- `REL-002`: the type column holds application class names
  (`Article`, `App\Models\Video`), two naming conventions in one column.
- Code: `<app/Models/Comment.php:14>` `morphTo()` (made-up path: cite the real one).

**Why it matters.** The database does not know what a comment belongs to. It
cannot stop a comment from pointing at nothing, cannot delete comments with
their article, and a reporting tool cannot discover the join: someone has to
hand it the rule. Renaming a class in the code silently detaches every
existing comment of that type.

**Fix.** Supertype table (decision rule in `polymorphic-associations.md`:
more targets expected, several tables point at them). With two stable targets
and a single child table, an exclusive arc would have been the answer.

```sql
<the adapted SQL: mapping, expand, backfill, quarantine, constrain, contract>
```

**Deploying it safely.** <order of steps, which need a release of the
application, which lock what; orphans to review first: n rows, exported how>

**Effort / risk.** <S / M / L> · <what could go wrong and how to roll back>

### F-02 · high · REL-004, REL-005 · <title>

<same structure>

### F-nn · low · DOC-001, DOC-002 · The schema documents nothing

**Evidence.** 12 of 12 tables in `shop` have no comment; <n> of <m> columns.
Examples: `shop.orders.status` (which values?), `shop.orders.total_amount`
(which currency, tax included?), `shop.orders.payload` (which shape?).

**Fix.** `COMMENT ON` for the <n> columns listed in appendix B first.

## 5. Rules found only in the application

The gap between what the code assumes and what the database enforces.

| Rule | Where in code | In the database? | Finding |
|---|---|---|---|
| A customer's email is unique | `<file:line>` | No unique index | F-04 |
| An order is deleted with its lines | `<file:line>` | `ON DELETE NO ACTION` | F-05 |
| Status is one of 5 values | `<file:line>` | No CHECK | F-06 |
| `updated_at` changes on every update | ORM timestamps | No trigger | F-07 |
| <...> | | | |

## 6. What is healthy

<Short and specific: it tells the team what to keep doing. Example (fixture):
the `clean` schema models the same comments with a supertype table and real
foreign keys; `shop.invoices.amount` is `numeric(12,2)`.>

## 7. Plan

| Horizon | Goal | Actions (finding) | Done when |
|---|---|---|---|
| Now (days) | Stop new damage | Add missing foreign keys and CHECKs as `NOT VALID` (F-02, F-06); revoke PUBLIC grants (F-09) | Re-run shows REL-004 = 0 |
| Next (weeks) | Repair | Quarantine orphans, `VALIDATE` constraints (F-01, F-02); partial unique indexes (F-03); FK indexes built `CONCURRENTLY` | REL-003, REL-005, REL-011 = 0 |
| Later (quarter) | Restructure | Replace the polymorphic pair (F-01); money to `numeric` (F-08); tenant keys and RLS (F-10); move rules of section 5 into the schema | REL-001 = 0; section 5 empty |

Re-run command, to measure progress with the same yardstick. Copy the
options of the approved run from section 3, no more: the same `--schemas`,
`--only`/`--skip` and `--set` values, and `--with-data` only if data probes
were allowed. Widening any of them needs a new authorisation.
`scripts/audit-schema.sh <options of the approved run> --format markdown --output <file>`

## 8. Reviewed and dismissed

<Candidates the script raised that are not findings, one line each with the
verified reason. Example: "REL-001 `audit_log (auditable_id, auditable_type)`:
append-only history, never joined; accepted, `COMMENT` requested.">

## 9. Open questions

<Things that need a human answer before they can become findings or be
dismissed. Example: "Is `shipments.legacy_ref_id` still written? By what?">

## Appendix A. Automated output

<Path to the JSON and markdown files produced by `audit-schema.sh`.>

## Appendix B. Lists

<Long enumerations referenced by the cards: tables, columns, indexes.>
````

---

## Finding card checklist

Before sending, each card must pass:

| Question | If the answer is no |
|---|---|
| Could the reader find the object with the evidence given? | Add schema, table, column or `file:line` |
| Did you apply the "Not a finding when" notes of the check? | Do it. Verified exclusion: move it to "Reviewed and dismissed". Reduced damage: lower one level and say why |
| Is the impact a consequence, not a restatement? | "No foreign key" is the evidence; "comments can point at deleted articles" is the impact |
| Is the fix runnable SQL with the real names (or, for a process defect such as backups, the evidence to produce)? | Write it; a principle is not a fix |
| Does the fix say how to deploy without an outage? | Add orphan handling, `NOT VALID`/`VALIDATE`, `CONCURRENTLY` |
| Would the severity survive the question "so what?" | Re-rate with the rubric in `SKILL.md` |
