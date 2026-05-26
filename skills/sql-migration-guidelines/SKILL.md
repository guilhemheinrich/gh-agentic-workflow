---
name: sql-migration-guidelines
description: >-
  Database-first SQL migration guidelines for relational schema changes with or
  without an ORM. Use when designing migrations, reviewing ORM-generated SQL,
  modeling polymorphic relations, enforcing referential integrity in PostgreSQL,
  adding table or column descriptions, timestamps, updated_at triggers, foreign
  keys, constraints, and indexes.
---

# SQL Migration Guidelines

## Purpose

Use this skill to design migrations where the database remains the source of
truth. ORM models may help generate or consume schema, but they must not hide
referential integrity, ownership rules, timestamps, or polymorphic behavior that
belongs in SQL.

## Default Workflow

1. Read the domain change and identify the persistent invariants: ownership,
   cardinality, lifecycle, deletion behavior, uniqueness, and query paths.
2. Design the SQL schema first: tables, primary keys, foreign keys, checks,
   indexes, comments, timestamps, and triggers.
3. Let the ORM mirror the database contract. If the ORM cannot express a
   database feature, add raw SQL in the migration rather than weakening the
   schema.
4. Review generated SQL before accepting it. Verify that constraints exist in
   PostgreSQL, not only in application code or ORM metadata.
5. Test the migration on a real PostgreSQL database, including insert/update,
   delete behavior, rollback or down migration, and backfill paths.

## Non-Negotiable Rules

- Prefer database-enforced integrity over ORM-only logic.
- Always add `created_at` and `updated_at` to every table, including parent,
  subtype, join, and lookup tables unless a documented exception is required.
- Maintain `updated_at` with a PostgreSQL trigger, not by relying only on
  application code.
- Add table and column descriptions with `COMMENT ON` when the database supports
  it. If the ORM supports comments, keep them aligned; if not, use raw SQL.
- Use real foreign keys with the same physical type as the referenced primary
  key. Do not store a fake foreign key in `varchar` unless the referenced key is
  itself `varchar`.
- Add indexes for foreign keys and common lookup columns. PostgreSQL does not
  automatically index referencing columns.
- Define delete semantics explicitly: `RESTRICT`, `CASCADE`, `SET NULL`, or
  `NO ACTION`. Do not let ORM defaults decide important lifecycle behavior.

## Polymorphic Relations

When a record must point to one of several target tables, always model a common
parent table, also called a supertype table. The dependent table references the
parent table with one normal foreign key.

Do not use the `type + id` pattern as the architecture:

```sql
-- Bad: no database-level referential integrity.
CREATE TABLE comments (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  body text NOT NULL,
  commentable_type varchar(50) NOT NULL,
  commentable_id varchar(50) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
```

This hides the real foreign key behind a string discriminator and an unvalidated
identifier. It makes orphan rows possible, couples integrity to one ORM, and
creates pain when changing ORM later.

Use a parent table instead:

```sql
CREATE TABLE comment_targets (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind text NOT NULL CHECK (target_kind IN ('article', 'video')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE comment_targets IS
  'Common parent table for all entities that can receive comments.';
COMMENT ON COLUMN comment_targets.target_kind IS
  'Classifier for the concrete target type. Not a substitute for a foreign key.';

CREATE TABLE articles (
  comment_target_id bigint PRIMARY KEY
    REFERENCES comment_targets(id) ON DELETE CASCADE,
  title text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE articles IS
  'Article-specific data for commentable article targets.';
COMMENT ON COLUMN articles.comment_target_id IS
  'Primary key shared with comment_targets and enforced by a foreign key.';

CREATE TABLE videos (
  comment_target_id bigint PRIMARY KEY
    REFERENCES comment_targets(id) ON DELETE CASCADE,
  url text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE comments (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  comment_target_id bigint NOT NULL
    REFERENCES comment_targets(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX comments_comment_target_id_idx
  ON comments(comment_target_id);
```

The `target_kind` column is metadata for querying and application branching; it
is not the referential-integrity mechanism. If the domain requires strict
consistency between `target_kind` and subtype tables, enforce it in PostgreSQL
with constraints, triggers, or controlled insert functions, not ORM-only checks.

Mention multi-column exclusive foreign keys or `type + id` only as legacy
patterns to migrate away from, not as preferred designs.

## Timestamp Trigger

Create one reusable trigger function per schema and attach it to every table
that has `updated_at`.

```sql
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER comment_targets_set_updated_at
BEFORE UPDATE ON comment_targets
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER articles_set_updated_at
BEFORE UPDATE ON articles
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER videos_set_updated_at
BEFORE UPDATE ON videos
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER comments_set_updated_at
BEFORE UPDATE ON comments
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
```

Prefer `timestamptz` for timestamps. Use `now()` or the project's established
UTC timestamp convention consistently.

## Table And Column Descriptions

Describe the database contract close to the database. Prefer PostgreSQL
comments for tables and columns, and mirror them in the ORM only when the ORM
supports it without losing the SQL source of truth.

```sql
COMMENT ON TABLE comments IS
  'User-authored comments attached to one commentable target.';
COMMENT ON COLUMN comments.comment_target_id IS
  'Foreign key to the common comment_targets parent table.';
COMMENT ON COLUMN comments.body IS
  'Raw comment body supplied by the user.';
```

Descriptions should explain business meaning, lifecycle, invariants, units,
privacy implications, and non-obvious constraints. Do not spend comments on
obvious restatements such as "primary key" when the SQL already says that.

## ORM Usage

- Use ORM migrations only if the emitted SQL keeps the database contract intact.
- Add raw SQL migration steps for comments, triggers, advanced constraints,
  partial indexes, exclusion constraints, or deferrable constraints when the ORM
  cannot model them.
- Keep ORM entity names and relation names clear, but treat them as a projection
  of the database schema.
- Never replace a real foreign key with an enum or string table name plus an
  arbitrary id to make an ORM relation easier.
- If changing ORM is a plausible future need, keep migrations plain and
  database-native enough that another ORM can introspect or map them without
  recovering hidden application rules.

## Migration Review Checklist

- Every table has `created_at`, `updated_at`, and an `updated_at` trigger.
- Every persistent relationship that must be valid has a real foreign key.
- Polymorphic relationships use a parent table and subtype tables.
- Table and column comments explain non-obvious business meaning.
- Foreign keys, lookup columns, and unique constraints have supporting indexes
  where query or delete paths need them.
- Nullability, defaults, checks, and uniqueness match the domain.
- Backfills are safe for existing data and large tables.
- Down migrations or rollback notes exist when the project expects them.
- The ORM schema matches the SQL schema rather than redefining hidden behavior.
