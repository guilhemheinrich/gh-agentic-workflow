# Glossary

For readers who are not database specialists. Each term: what it is, then an
example. "Fixture" = `scripts/fixtures/fixture-schema.sql`, a small shop
database with deliberate defects that ships with this skill; line numbers
refer to it. Examples not taken from a file are marked "made-up".

## The data model

**Table, row, column.** A table is a list of things of one kind; a row is one
thing; a column is one property. *Example:* the `shop.orders` table (fixture
line 54) has one row per order and a `total_amount` column.

**Primary key (PK).** The column that identifies a row uniquely, usually `id`.
*Example:* `shop.orders.id`. The fixture's `shop.order_items` (line 82) has
none: two identical lines cannot be told apart (check `REL-007`).

**Foreign key (FK).** A declared link: "this column holds the id of a row in
that table", enforced by the database, which refuses a value that matches
nothing. *Example:* `customer_id integer NOT NULL REFERENCES shop.customers(id)`
(fixture line 57). Counter-example: `shop.order_items.order_id` (line 83) is
only *named* like a link; the database accepts order 7777, which does not exist.

**Referential integrity.** The guarantee that every link points at something
that exists. It holds only where foreign keys exist.

**Orphan row.** A row whose link points at nothing. *Example:* the fixture
comment with `commentable_id = 999` when there is no article 999 (`REL-003`).

**ON DELETE rule.** What happens to the children when the parent row is
deleted: `CASCADE` (delete them too), `SET NULL` (detach them), `RESTRICT` /
`NO ACTION` (refuse the delete). *Made-up example:* deleting an order with
`ON DELETE CASCADE` on `order_items.order_id` removes its lines; with nothing
declared, the delete is refused, or, with no foreign key at all, the lines
become orphans.

**Constraint.** A rule the database checks on every write. The kinds:
`NOT NULL` (a value is required), `UNIQUE` (no duplicates), `CHECK` (a
condition, such as `quantity > 0`), foreign key. *Example:*
`CHECK (target_kind IN ('article', 'video'))` (fixture line 227).

**Natural key / surrogate key.** A natural key is what makes a row unique in
the real world (an order number, an ISO country code). A surrogate key is a
generated number with no meaning (`id`). A table with only a surrogate key
can hold the same real-world thing twice (`CON-004`).

**Schema.** Two meanings: the overall structure of a database (its tables,
columns, constraints), and a PostgreSQL namespace grouping tables
(`shop.orders` is table `orders` in schema `shop`).

**Catalog.** The database's own description of itself, stored in system tables
(`pg_catalog`, `information_schema`). The audit reads the catalog to learn the
structure without touching business data. *Example:* `pg_constraint` lists
every foreign key.

**Comment.** A description stored in the database with a table or column
(`COMMENT ON ...`), visible to every tool. *Example:* fixture line 275.

## The anti-patterns

**ORM (object-relational mapper).** A library that lets application code
handle rows as objects: ActiveRecord (Rails), Eloquent (Laravel), Django ORM,
Hibernate, TypeORM, Prisma, Drizzle, Sequelize, SQLAlchemy.

**ORM leakage.** A rule about the data that exists only in the ORM's code, so
the database does not enforce it and other programs do not know it. *Made-up
example:* "emails are unique" written as a validation in a model, with no
unique index in the database.

**Polymorphic association.** One column that can point at rows of several
tables, with a second column saying which. *Example:* fixture lines 49-50,
`commentable_id` + `commentable_type`. No foreign key is possible, so the
database cannot check or even describe the link. See
[polymorphic-associations.md](polymorphic-associations.md).

**Discriminator.** The column that says "which kind": `commentable_type` in a
polymorphic pair, `type` in single-table inheritance, `target_kind` in a
supertype table. Harmless as a label; harmful when it replaces a foreign key.

**Exclusive arc.** One real foreign-key column per possible target, plus a
rule that exactly one is filled. *Example:* fixture line 261,
`CHECK (num_nonnulls(article_id, video_id) = 1)`.

**Supertype / subtype tables.** A parent table holding what several kinds have
in common (here: "something that can be commented on"), and one table per
kind sharing the parent's key. Others then link to the parent with one
ordinary foreign key. *Example:* `clean.comment_targets`, `clean.articles`,
`clean.videos` (fixture lines 225-242).

**Single-table inheritance (STI).** Several kinds of thing stored in one table
with a `type` column and columns that are empty for some kinds. *Made-up
example:* a `documents` table holding invoices and quotes, where `due_date` is
filled only when `type = 'Invoice'`.

**Soft delete.** Marking a row as deleted (`deleted_at` filled) instead of
removing it. The ORM hides such rows; a reporting tool reading the table
directly does not. *Example:* `shop.orders.deleted_at` (fixture line 64).

**Partial index.** An index covering only the rows that satisfy a condition.
Needed with soft delete so that uniqueness applies to live rows only.
*Made-up example:* `CREATE UNIQUE INDEX ... ON orders (order_number) WHERE deleted_at IS NULL`.

**Denormalisation.** Storing the same fact in two places, usually for speed.
Safe only if something keeps the copies equal. *Example:*
`shop.orders.customer_email` (fixture line 61) copies `shop.customers.email`;
nothing updates it when the customer changes address (`DUP-001`).

**Enum as free text.** A column that should accept a short fixed list of
values but is typed as unrestricted text. *Example:* `shop.orders.status`
(fixture line 59) accepts `'payd'`.

**State machine.** The set of allowed moves between statuses. *Made-up
example:* an order may go `draft -> paid -> shipped` but never `shipped -> draft`.

**Money as float.** Storing amounts in a binary floating-point type, which
cannot represent most decimal fractions exactly: `0.1 + 0.2` yields
`0.30000000000000004`. *Example:* `shop.orders.total_amount double precision`
(fixture line 60).

**Timestamp without time zone.** A date and time with no indication of where:
"2026-03-29 02:30" is ambiguous or even nonexistent depending on the zone.
`timestamptz` stores an exact instant. *Example:* `shop.customers.created_at`
(fixture line 29).

**JSON blob.** A column holding a free-form document. Fine for opaque
payloads; a problem when it hides data that other rows depend on. *Example:*
`shop.orders.payload` holds `product_id` (fixture line 194), a link no foreign
key protects.

**N+1 queries.** Fetching a list with one query, then one more query per item
instead of a single joined query. *Made-up example:* showing 200 orders with
their customer runs 201 queries. Typical of ORM lazy loading (`OPS-005`).

## Multi-tenancy and security

**Tenant.** One customer organisation in a system shared by several.
**Multi-tenant leakage** = data of one tenant visible or linkable from
another. *Example:* in the fixture an order of tenant 1 could reference a
customer of tenant 2, because the foreign key ignores `tenant_id` (`TEN-002`).

**Row-level security (RLS).** Rules stored in the database that filter which
rows a session may see or change, whatever query it runs. *Made-up example:*
`CREATE POLICY tenant_isolation ON orders USING (tenant_id = current_setting('app.tenant_id')::uuid);`
With RLS on and no policy, ordinary roles see nothing; the table owner,
superusers and `BYPASSRLS` roles see everything (`TEN-004`). RLS filters rows,
never columns, and a role can `SET app.tenant_id` itself: such a policy only
holds against callers that cannot issue SQL.

**SECURITY DEFINER function.** A function that runs with the rights of the
role that owns it, not of the caller. Useful, and dangerous when the function
looks names up through an unpinned `search_path`: a caller who creates their
own table or function with the expected name gets it executed with the
owner's rights (`SEC-009`).

**Role, grant, least privilege.** A role is a database account or group; a
grant gives it a right (read this table, write that one). Least privilege =
each program gets only the rights it needs. *Made-up example:* the web
application's role can read and write rows but cannot drop a table; the
reporting role can only read.

**PUBLIC.** The pseudo-role meaning "everyone, including accounts created
later". *Example:* `GRANT SELECT ON shop.customers TO PUBLIC` (fixture line 33).

**pg_hba.conf.** The PostgreSQL file that decides who may connect, from where,
and how they prove their identity. `trust` means "no proof required".

**PII (personally identifiable information).** Data about a person: name,
email, phone, address, identifiers. The audit inventories the columns likely
to hold it by name (`SEC-007`) and never reads the values.

## Operations

**Index.** A lookup structure that lets the database find rows without reading
the whole table. Costs space and slows writes, so unused and duplicate indexes
are waste (`IDX-002`, `IDX-003`); a missing one on a foreign key makes joins
and parent deletes slow (`IDX-001`).

**Dead tuples, bloat, VACUUM.** PostgreSQL keeps old versions of updated or
deleted rows until VACUUM reclaims them. If it cannot keep up, tables grow
with dead space: bloat. *Example:* the fixture's `shop.churn` (line 137) has
4500 dead rows for 500 live ones.

**Sequence.** The counter that generates ids. A 32-bit `integer` id stops at
2 147 483 647; the next insert fails. *Example:* the fixture pushes
`shop.orders_id_seq` to 1 900 000 000, 88% of the range (`OPS-001`).

**Transaction.** A group of changes applied all together or not at all. A
transaction left open for a long time blocks maintenance and can block other
sessions (`OPS-003`).

**Lock.** The database's way of preventing two operations from colliding. Some
schema changes take a lock that blocks every reader and writer of the table
until they finish.

**Migration.** A script that changes the structure (adds a column, a
constraint). **Migration safety** = doing it without blocking or breaking the
running application. Key tools: `CREATE INDEX CONCURRENTLY` (builds an index
without blocking writes), `NOT VALID` then `VALIDATE CONSTRAINT` (adds a rule
for new rows first, checks old rows afterwards without blocking).

**Expand / contract.** Changing a structure in steps the application can
follow: add the new shape, write both, move the data, read the new, remove
the old. Used to replace a polymorphic pair without downtime.

**WAL, PITR, replica.** The write-ahead log (WAL) records every change.
Archiving it allows point-in-time recovery (PITR): restoring the database as
it was at a chosen minute. A replica is a live copy fed by the WAL; audits
should read from one when possible. A replica is not a backup: a mistaken
`DELETE` is replicated within seconds.

**Replication slot.** A bookmark the server keeps for one consumer of the
WAL. The server refuses to recycle WAL the consumer has not read yet; if the
consumer is gone, the WAL piles up until the disk is full (`OPS-008`).

**Transaction ID wraparound.** PostgreSQL numbers transactions with a counter
that must be recycled by VACUUM; if recycling is blocked for too long the
database stops accepting writes to protect itself (`OPS-007`).

**BI / ETL.** Business-intelligence tools draw reports straight from the
database; extract-transform-load jobs copy it into a warehouse. Both read the
schema, not the application code, which is why undeclared rules hurt them first.

**Read-only audit.** The audit only reads. The session is opened in a mode
where the server refuses data and schema changes, so a faulty check cannot
alter data (`scripts/lib/run-checks.sh`, verified by `scripts/test-audit.sh`).
It is not a sandbox: a function with outside effects could still run, which
is why every check is a reviewed `SELECT` on catalogs and statistics.
