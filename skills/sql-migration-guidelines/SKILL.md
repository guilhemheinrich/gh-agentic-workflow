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

The database is the source of truth. The ORM mirrors the schema; it must not
hide integrity, ownership, timestamps or polymorphism that belongs in SQL. If
the ORM cannot express a feature, add raw SQL to the migration instead of
weakening the schema. Review generated SQL, and test the migration (including
rollback and backfill) on a real PostgreSQL.

## Rules

- Database-enforced integrity over ORM-only logic.
- Every table has `created_at` and `updated_at` (`timestamptz`), including
  subtype, join and lookup tables. `updated_at` is maintained by a trigger:
  `templates/updated-at-trigger.sql`.
- Table and column descriptions via `COMMENT ON`: `templates/comments.sql`.
- Real foreign keys, with the same physical type as the referenced key.
- Index foreign keys and common lookup columns.
- Declare delete semantics explicitly (`RESTRICT`, `CASCADE`, `SET NULL`,
  `NO ACTION`); never let ORM defaults decide.
- Never replace a foreign key with an enum or table-name string plus an id.

## Polymorphic relations

Use a common parent (supertype) table referenced by one normal foreign key;
subtype tables share its primary key. See
`templates/polymorphic-parent-table.sql`. `target_kind` is a classifier, not
the integrity mechanism: if kind and subtype must agree, enforce it with
constraints, triggers or insert functions in PostgreSQL. Treat `type + id` and
multi-column exclusive foreign keys as legacy to migrate away from.

## Review checklist

- `created_at`, `updated_at` and the trigger exist on every table.
- Every relationship that must be valid has a real foreign key and index.
- Nullability, defaults, checks and uniqueness match the domain.
- Comments explain non-obvious meaning.
- Backfills are safe on existing and large tables.
- A down migration or rollback note exists when the project expects one.
- The ORM schema matches the SQL rather than redefining hidden behavior.
