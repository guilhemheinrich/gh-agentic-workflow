# Polymorphic associations by convention

The headline anti-pattern of this audit. Checks: `REL-001` (catalog), `REL-002`
and `REL-003` (data probes), `ORM-001` (code).

## The shape

One table must point at rows of several other tables ("a comment is on an
article *or* a video"). The ORM-first answer is a pair of columns:

```sql
-- scripts/fixtures/fixture-schema.sql:47-52
CREATE TABLE shop.comments (
  id               bigserial PRIMARY KEY,
  commentable_id   bigint NOT NULL,   -- an id ... in which table?
  commentable_type text   NOT NULL,   -- 'Article', 'App\Models\Video', ...
  body             text   NOT NULL
);
```

`commentable_id = 7` means "article 7" on one row and "video 7" on the next.
The rule that turns `commentable_type` into a table name is not in the
database. It is in the ORM, as a convention:

| ORM | The value stored in the type column | Where the mapping lives |
|---|---|---|
| Rails | Class name: `Article`, `Blog::Post` | `belongs_to :commentable, polymorphic: true` |
| Laravel | Fully qualified class `App\Models\Video`, or an alias | `morphTo()`, `Relation::enforceMorphMap([...])` |
| Django | An integer id of `django_content_type` | `GenericForeignKey('content_type', 'object_id')` |
| TypeORM, Prisma, Drizzle, Sequelize | Whatever string the developer chose | Hand-written `if (type === 'article')` in services |

## Why it is the worst finding in the report

Read these as five separate, checkable claims.

1. **No foreign key is possible.** A foreign key names exactly one referenced
   table. So nothing stops `commentable_id = 999` when article 999 does not
   exist. Fixture proof: `REL-003` reports "1 of 3 sampled rows are orphans: no
   row in shop.articles with id = commentable_id".
2. **No `ON DELETE`.** Deleting an article leaves its comments behind unless the
   ORM callback runs. A `DELETE` typed in `psql`, a bulk job or another service
   skips the callback.
3. **The schema is unreadable without the application.** An ER diagram shows
   `comments` connected to nothing. A BI tool cannot discover the join; someone
   must hand it the mapping. An ETL job
   must hard-code the class-name mapping, which then breaks when a developer
   renames `Video` to `Clip`. Fixture proof: the type column holds both
   `'Article'` and `'App\Models\Video'`, two naming conventions in one column.
4. **The type column is free text.** A typo creates a new "type" that points
   nowhere. Fixture proof: `REL-003` reports `commentable_type = 'Ghost'`:
   "type value names no table".
5. **Joins are conditional and unindexable as one.** Every query needs
   `LEFT JOIN articles ON type = 'Article' AND id = ...` per target, and adding
   a target means editing every such query.

There is one more cost that surfaces late: **a rename in code is a data
migration**. Made-up example: renaming the PHP class `App\Models\Video` to
`App\Media\Video` silently orphans every existing row, because the old string
is still stored.

## Detection in the database

### Catalog (no data access needed) - `REL-001`

`scripts/sql/REL-001-polymorphic-pair.sql` pairs a column ending in
`_id / Id / _uuid / _key / _ref / _pk` with a sibling ending in
`_type / Type / _kind / _class / _model / _table / _entity` that shares its
prefix, and keeps the pair when the id column has no foreign key. A second
branch catches Django (`object_id` next to a `content_type_id` that *is* a
foreign key).

`information_schema` version for a manual run on another engine. Tested on
PostgreSQL 16 and MySQL 8; standard SQL, but **not** tested on SQL Server.

```sql
SELECT i.table_schema, i.table_name, i.column_name AS id_column, t.column_name AS type_column
FROM information_schema.columns i
JOIN information_schema.columns t
  ON t.table_schema = i.table_schema AND t.table_name = i.table_name
 -- swap the suffix only: the '$' sentinel keeps an inner "_id" (sub_id_ref_id) intact
 AND concat(t.column_name, '$') = replace(concat(i.column_name, '$'), '_id$', '_type$')
WHERE i.column_name LIKE '%!_id' ESCAPE '!'
  AND i.table_schema NOT IN ('information_schema', 'pg_catalog', 'mysql', 'sys', 'performance_schema')
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage k
    JOIN information_schema.table_constraints c
      ON c.constraint_schema = k.constraint_schema AND c.constraint_name = k.constraint_name
     AND c.table_schema = k.table_schema AND c.table_name = k.table_name
    WHERE c.constraint_type = 'FOREIGN KEY'
      AND k.table_schema = i.table_schema AND k.table_name = i.table_name
      AND k.column_name = i.column_name);
```

Three traps this version avoids, each reproduced before the fix: `ESCAPE '\'`
is a syntax error on MySQL (the backslash escapes the quote); on PostgreSQL a
constraint name is unique per table, not per schema, so the join needs the
table; `replace(col, '_id', '_type')` rewrites every `_id` in the name. One
trap it cannot avoid: **on PostgreSQL, `information_schema.table_constraints`
only shows constraints of tables the current role owns or may write to.** A
`SELECT`-only audit role sees none (verified: 0 rows, against 6 for the
owner), so every pair looks unconstrained. On PostgreSQL use the script, which
reads `pg_constraint`.

Also list the `*able_*` names, a strong Rails/Laravel signal even when one
column of the pair was renamed:

```sql
SELECT table_schema, table_name, column_name
FROM information_schema.columns
WHERE column_name ~ '(able|ible)_(id|type)$'      -- MySQL: REGEXP, SQL Server: LIKE '%able[_]id'
  AND column_name <> 'table_type'
  AND table_schema NOT IN ('information_schema', 'pg_catalog')
ORDER BY 1, 2, 3;
```

### Values that are table names - `REL-002` (data probe)

A pair named `(ref, src)` escapes any name-based rule. `REL-002` samples the
distinct values of text columns named like a discriminator and compares them,
after stripping namespaces and plurals, to the table names. Fixture output:
`shop.comments.commentable_type: 2 of 3 sampled distinct values name a table:
App\Models\Video -> videos, Article -> articles`.

Manual version for one suspect column:

```sql
SELECT commentable_type, count(*) FROM shop.comments GROUP BY 1 ORDER BY 2 DESC;
```

### Orphans - `REL-003` (data probe)

The number that makes the finding concrete. Per type value:

```sql
SELECT count(*) AS orphans
FROM shop.comments c
WHERE c.commentable_type = 'Article'
  AND NOT EXISTS (SELECT 1 FROM shop.articles a WHERE a.id = c.commentable_id);
```

Run it once per distinct type value, with the target table taken from the
application's mapping, not guessed from the value. A type value that matches
no table is an **unknown mapping** until the code explains it: Laravel
`morphMap` aliases (`'post'` for `App\Models\Article`) and Django content-type
ids name no table and are perfectly valid. Only a value the code cannot
explain either is a finding (its rows are unreachable). If RLS applies to the
audit role on either table (`ACC-001`), the count is "in this role's view".

### Tables with no foreign key at all - `REL-008`

A table that is connected to nothing in the catalog but has id-like columns is
where polymorphic and undeclared references hide.

### False positives to rule out before reporting

| Looks like the anti-pattern | Why it may be fine | How to tell |
|---|---|---|
| Audit or event log (`auditable_id`, `auditable_type`; `item_id`, `item_type`) | History must survive the deletion of its subject, so a foreign key is unwanted | The table is append-only and never joined for business logic. Report as "accepted, document it with a `COMMENT`" |
| External reference (`provider_id`, `provider_type` = 'stripe') | The id lives in another system | Type values name vendors, not tables (`REL-002` is silent) |
| Supertype classifier (`target_kind` in the parent table) | The id is a real key; the kind only labels the subtype | No id column next to it; subtype tables have a foreign key back (`REL-002` already excludes this) |
| Single-table inheritance (`type` naming the row's own class) | It classifies the row itself, it does not point elsewhere | The value names the same table, or no table (see `ORM-011`) |

## Detection in the code - `ORM-001`

Run from the repository root. Each hit is a **candidate**: open the file and
confirm it is a relation whose target table is chosen per row (the name-based
patterns for TypeORM, Drizzle and Sequelize also match unrelated `...Type`
fields). The patterns are extended regular expressions (`grep -E`); adapt the
directories to the project layout.

```bash
# Rails
grep -rnE "polymorphic: *true|as: *:[a-z_]+able|references .*polymorphic" app db
# Django
grep -rnE "GenericForeignKey|GenericRelation|contenttypes" --include='*.py' .
# Laravel
grep -rnE "morphTo\(|morphMany\(|morphOne\(|morphToMany\(|morphedByMany\(|[mM]orphs\(|morphMap" app database
# TypeORM
grep -rnE "PolymorphicParent|PolymorphicChildren|createForeignKeyConstraints: *false|(entity|target|owner|subject|resource)Type" --include='*.ts' src
# Prisma
grep -nE "^ +[A-Za-z_]+(Type|_type) +String" prisma/schema.prisma        # relationMode = "prisma" is ORM-002, not polymorphism
# Drizzle
grep -rnE "(entity|target|owner|subject|resource|[a-z]+able)(Type|_type)" --include='*.ts' src
# Sequelize
grep -rnE "constraints: *false|[a-z]+able(Type|_type|Id|_id)" --include='*.js' --include='*.ts' .
# Hibernate / JPA
grep -rnE "@Any$|@Any[^a-zA-Z]|@AnyDiscriminator|@ManyToAny|ConstraintMode\.NO_CONSTRAINT" --include='*.java' --include='*.kt' .
# SQLAlchemy
grep -rnE "generic_relationship|primaryjoin=.*_type *==|foreign\(.*remote\(" --include='*.py' .
```

Also search the services for the hand-written dispatch that replaces the
foreign key. Made-up example of what a hit looks like:

```ts
// src/comments/comment.service.ts (made-up)
const target = c.targetType === 'article'
  ? await db.query.articles.findFirst({ where: eq(articles.id, c.targetId) })
  : await db.query.videos.findFirst({ where: eq(videos.id, c.targetId) });
```

For each code hit, record: file and line, the table and pair of columns, the
list of possible targets (from `morphMap`, from the models declaring
`as: :commentable`, or from the `REL-002` values). That list is the input of
the remediation.

## Remediation

Four patterns. All four are applied to the fixture, with the forbidden writes
asserted, in `scripts/fixtures/remediation-polymorphic.sql`; `scripts/test-audit.sh`
runs it and checks `REL-001..REL-005` are then silent.

### Choosing

A (exclusive arc) and B (supertype table) both give real foreign keys. Neither
is "the right one" in general; they fit different situations.

| Question | Exclusive arc (A) fits when | Supertype table (B) fits when |
|---|---|---|
| How many targets, how stable? | 2 to 4, not expected to grow | Open-ended: targets are added over time |
| How many tables point at the same set of targets? | One (only `comments`) | Several (`comments`, `tags`, `attachments` all point at "commentable things") |
| How much can change now? | The live table only: add columns, backfill, constrain | A new table, a new column on every target, and a lifecycle rule (below) |
| What does a new target cost later? | One column, one index, and the `CHECK` edited | One table; no existing query changes |
| What does a reader see? | The target directly: `comments.article_id -> articles.id` | One hop more: `comments -> comment_targets -> articles` |

Decision rule: **if the first two answers are "few, stable" and "one", choose
A; otherwise choose B.** This repository's `skills/sql-migration-guidelines`
prefers B (one ordinary, typed foreign key through a parent table) and treats
exclusive arcs as legacy to migrate away from. In a codebase that follows that
guideline, A is still a legitimate *step*: record it as an exception, or as the
first stage of a move to B. Elsewhere, A is a sound end state.

Made-up examples. A `notes` table attached to either a customer or a supplier,
nothing else planned: A. A `comments` table on articles and videos, with
podcasts and events on the roadmap and a `reactions` table wanting the same
targets: B.

Three other cases:

| Situation | Pattern | Why |
|---|---|---|
| The child can attach to several targets at once, or the attachment carries its own data (position, role) | **C. One join table per target** | Many-to-many per target; the child table stays target-agnostic |
| Targets have nothing in common; the "shared" child was a coincidence of naming | **D. One child table per target** | Strongest and simplest integrity; a `UNION ALL` view serves "all of them" |
| Append-only audit/event log | Keep the pair | Add `CHECK (x_type IN (...))` and a `COMMENT` saying integrity is deliberately not enforced |

### A. One foreign key column per target (exclusive arc)

```sql
ALTER TABLE comments
  ADD COLUMN article_id bigint REFERENCES articles (id) ON DELETE CASCADE,
  ADD COLUMN video_id   bigint REFERENCES videos (id)   ON DELETE CASCADE,
  ADD CONSTRAINT comments_exactly_one_target
    CHECK (num_nonnulls(article_id, video_id) = 1);
CREATE INDEX comments_article_id_idx ON comments (article_id);
CREATE INDEX comments_video_id_idx   ON comments (video_id);
```

This is the target shape. On a populated table the `CHECK` fails at once
(existing rows have neither column filled): add the columns first, backfill,
and add the constraints last, as in the migration steps below.

Variants of the `CHECK`: `= 1` exactly one target (exclusive arc); `<= 1` an
optional target; no check when a row may legitimately attach to several
targets at once. `num_nonnulls` is PostgreSQL; elsewhere write
`(article_id IS NOT NULL) + (video_id IS NOT NULL) = 1` (MySQL) or a sum of
`CASE WHEN ... IS NOT NULL THEN 1 ELSE 0 END` (SQL Server).

Cost: one nullable column and one index per target, and the `CHECK` must be
edited for each new target.

### B. Supertype table

New schema: use `skills/sql-migration-guidelines/templates/polymorphic-parent-table.sql`
(subtypes share the parent's primary key). Existing schema whose targets
already have their own ids: the **target shape** is below. It is not a script
to run as is on a live database; the live order follows, and the whole
sequence is executed in `scripts/fixtures/remediation-polymorphic.sql`.

```sql
CREATE TABLE comment_targets (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind text NOT NULL CHECK (target_kind IN ('article', 'video')),
  UNIQUE (id, target_kind)                       -- lets a subtype prove its kind
);
-- articles gains (same for videos with 'video'):
--   comment_target_id bigint NOT NULL UNIQUE
--   target_kind       text   NOT NULL DEFAULT 'article' CHECK (target_kind = 'article')
--   FOREIGN KEY (comment_target_id, target_kind)
--     REFERENCES comment_targets (id, target_kind) ON DELETE CASCADE
-- comments gains:
--   comment_target_id bigint NOT NULL REFERENCES comment_targets (id) ON DELETE CASCADE
--   plus an index on it; the (commentable_id, commentable_type) pair is dropped last
```

Order on a live database (it refines the generic steps of the next section):

1. **Expand.** Create `comment_targets`; add `comment_target_id` and
   `target_kind` to each target table and `comment_target_id` to `comments`,
   all **nullable**.
2. **Dual-write, every writer first.** Application, jobs, imports and other
   services create the parent row with each new article or video, and fill
   `comments.comment_target_id` next to the old pair, in the same
   transaction. A writer you cannot change is retired, or covered by a
   trigger that fills the new columns. Check: no row created since the deploy
   has the new column NULL.
3. **Backfill** the existing rows: one parent per article and video, then the
   comments through the type mapping.
4. **Reconcile.** Count rows still NULL and comments whose new link disagrees
   with the old pair. A NULL left by a late writer is a missed backfill, not an
   orphan: fix the writer and re-run step 3. Quarantine only comments whose
   *mapped* target is missing.
5. **Enforce.** `CREATE UNIQUE INDEX CONCURRENTLY` on `articles (comment_target_id)`,
   attach it with `ADD CONSTRAINT ... UNIQUE USING INDEX`; foreign keys
   `NOT VALID` then `VALIDATE`; `NOT NULL` through a validated `CHECK` (as in
   `CON-003`'s fix). Verified: a `NOT VALID` `CHECK (... IS NOT NULL)` refuses
   to validate while one row is NULL, and blocks an old writer once added.
6. Switch reads, then contract (steps 6 and 7 of the next section).

Four things the shape does **not** give for free. Each is asserted in the fixture.

- **The classifier can lie without the composite key.** With
  `(comment_target_id, target_kind)` an article cannot claim a parent labelled
  `video`. With a plain foreign key on `comment_target_id` it can.
- **A target without a parent is possible while the column is nullable.** A
  composite foreign key with a NULL member is not checked at all (default
  `MATCH SIMPLE`). Hence `NOT NULL` at the end of step 3.
- **Deletes only cascade downwards.** Deleting the parent row removes the
  article and its comments. Deleting the *article* directly leaves the parent
  row and the comments behind. Pick one rule and enforce it: an `AFTER DELETE`
  trigger on each target table that deletes the parent (what the fixture
  does), or revoke `DELETE` on the target tables from the application role
  and delete through the parent only.
- **A parent with no subtype is a target that does not exist.** Nothing above
  stops `INSERT INTO comment_targets` alone, then a comment on it; nor an
  `UPDATE` re-pointing an article at another parent, which strands the old
  one without firing a delete trigger. First ask whether a bare parent is a
  valid object in the domain (a draft, a tombstone). If not, enforce it: a
  `DEFERRABLE INITIALLY DEFERRED` constraint trigger on `comment_targets` that
  requires a subtype row at commit, and a trigger that refuses any change of
  `comment_target_id` (what the fixture does); or revoke direct writes and
  create both rows through one function.

Cost: one extra table, one extra join, and that lifecycle rule to maintain.

### C. One join table per target

```sql
CREATE TABLE article_comments (
  comment_id bigint PRIMARY KEY REFERENCES comments (id) ON DELETE CASCADE,
  article_id bigint NOT NULL REFERENCES articles (id) ON DELETE CASCADE
);
CREATE INDEX article_comments_article_id_idx ON article_comments (article_id);
-- video_comments likewise
```

`comment_id` as primary key means "a comment joins at most one article". Use
`PRIMARY KEY (comment_id, article_id)` for many-to-many. Cost: the database
does not prevent one comment from appearing in both `article_comments` and
`video_comments`; if that must be impossible, prefer A or B.

### D. One child table per target

```sql
CREATE TABLE article_comments (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  article_id bigint NOT NULL REFERENCES articles (id) ON DELETE CASCADE,
  body       text NOT NULL
);
-- video_comments likewise; reporting reads a view:
CREATE VIEW all_comments AS
  SELECT 'article' AS target, article_id AS target_id, body FROM article_comments
  UNION ALL
  SELECT 'video', video_id, body FROM video_comments;
```

Cost: duplicated structure; a column added to "comments" is added N times.

## Migrating a live table (expand, backfill, constrain, contract)

The order matters; each step is deployable on its own. Worked end to end for
pattern A in `scripts/fixtures/remediation-polymorphic.sql` (steps A1 to A5).

1. **Write down the mapping** from stored type values to targets. It is the
   knowledge that only the ORM had. Take it from the code (morph map, model
   names, history of renames), then check it against a full `SELECT DISTINCT`
   of the type column run by the team. `REL-002` samples 30 values: a
   cross-check, not the list. `'Video'` and `'App\Models\Video'` are the same
   target.
2. **Expand.** Add the new nullable columns (A) or the supertype table (B).
   Then every writer (application, jobs, imports, other services) writes both
   the old pair and the new columns, before any backfill.
3. **Backfill** only the rows whose target exists; then count what is still
   NULL: a row a writer missed is a backfill gap, not an orphan.
4. **Quarantine what is left** in a side table with the original row and a
   timestamp, only after the mapping of step 1 is complete and the data owner
   has seen the list. A row is an orphan when its *mapped* target is missing,
   never because its type value was not recognised. Do not delete silently.
5. **Constrain.** `ADD CONSTRAINT ... NOT VALID` (short lock, new rows are
   checked immediately), commit, then `VALIDATE CONSTRAINT` in its own
   transaction (no write lock). Build indexes with `CREATE INDEX CONCURRENTLY`.
6. **Switch reads** in the application. Keep a compatibility view exposing the
   old pair for exports and reports that cannot move yet; define it on the
   **new** columns, otherwise it blocks the drop of the old ones.
7. **Contract.** Dropping the pair destroys the only copy of the old mapping,
   so "nobody queried it lately" is not enough. Required: an inventory of
   readers (application, BI, ETL, exports) with each owner's confirmation; an
   observation window that covers the slowest cycle (a quarterly export means
   a quarter); nothing in `pg_depend` depending on the columns; a backup of
   the two columns keyed by id. `pg_stat_statements` is supporting evidence
   only: it gets reset, it evicts entries, and it never saw a job that has not
   run yet. The data owner authorises the drop. Drop the view last.

## What to write in the report

- The pair, the table, the row count, the list of targets, the orphan count
  per target, the type values that name nothing.
- One sentence for non-specialists, for example: "The `comments` table does
  not record which kind of thing a comment belongs to in a way the database
  understands; 1 of the 3 sampled comments on articles already points at an
  article that does not exist, and a reporting tool cannot link comments to
  articles unless someone gives it the rule."
- The chosen pattern with the reason from the table above, and the seven
  steps with the SQL adapted to the real names.
