---
name: philosophy-data-first
description: >-
  Data-First & State Transitions philosophy: every use case is an atomic
  database transaction from an initial state to a committed final state;
  external or async effects go through a job orchestrator (pg-boss or
  equivalent) enqueued in the same transaction; the data layer uses an ORM
  that exposes the physical model (e.g. Drizzle). Use when adopting or
  refining this philosophy in a repository, writing it into PHILOSOPHY.md,
  choosing the job orchestrator or ORM it requires, or writing a use-case
  spec as a state transition. Philosophie data-first, transitions d'état.
---

# Philosophy — Data-First & State Transitions

## Purpose

Install and maintain the *Data-First & State Transitions* philosophy in a
repository. The content to write lives in
[references/data-first.md](references/data-first.md); the procedure to write,
amend and reference `PHILOSOPHY.md` is the `project-philosophy` skill. Follow
it — this skill only adds what is specific to this philosophy.

## Core idea (summary)

- The database is the source of truth of **state**; code is the author of
  **transitions**. Critical invariants live in the database.
- One use case = one atomic transaction: trigger → preconditions → committed
  final state.
- No external I/O inside a transaction: external or async effects are **jobs
  enqueued in the same transaction**, and each job is itself a use case.
- Responses, callbacks and egress calls are **consequences** of the committed
  state, never the state itself.

## Workflow

1. **Inspect** the stack (database engine, language, existing ORM, existing
   queue/worker) and the current `PHILOSOPHY.md`, if any.
2. **Required decision — job orchestrator.** If `PHILOSOPHY.md` has no chosen
   orchestrator, stop and ask the human. Present options filtered by the stack:

   | Option | Stack | Same-transaction enqueue |
   |---|---|---|
   | pg-boss | Node + PostgreSQL | yes |
   | Graphile Worker | Node + PostgreSQL | yes |
   | River | Go + PostgreSQL | yes |
   | Procrastinate | Python + PostgreSQL | yes |
   | Oban | Elixir + PostgreSQL | yes |
   | Temporal, BullMQ/Redis, SQS… | any | **no** → transactional outbox table required |

   Decisive criterion: can the job insert share the business transaction? If
   not, the decision must also record the outbox table and its relay.
3. **Required decision — ORM / query builder.** Ask if not decided. It must
   expose the physical model rather than hide it:
   - typed schema close to SQL: constraints, `CHECK`, enums, partial and
     composite indexes, `ON DELETE` behavior, column comments;
   - explicit, typed transactions that the job orchestrator can join;
   - readable SQL migrations that can be reviewed and hand-completed.

   Defaults to propose: **Drizzle** (TypeScript), SQLAlchemy 2.x Core/ORM +
   Alembic (Python), sqlc (Go), Ecto (Elixir). Prefer an ORM that lets the
   orchestrator enqueue inside its transaction — for Drizzle + pg-boss
   (>= 12.17.0, `fromDrizzle` adapter) follow the `drizzle-pg-boss` skill.
   Whatever the ORM cannot express is written in SQL in the migration.
4. **Write** the content of [references/data-first.md](references/data-first.md)
   into `PHILOSOPHY.md` following `project-philosophy` (amend, don't overwrite;
   fill *Décisions d'implémentation* with the choices from steps 2–3, or leave
   `à choisir` and report it).
5. **Reference** `PHILOSOPHY.md` from `AGENTS.md` / `CLAUDE.md` (procedure in
   `project-philosophy`).

## Writing a use case under this philosophy

Use the template of section 2 of `references/data-first.md`. Check before
accepting a spec:

- Preconditions and transitions name real tables/columns of the model.
- No external call is listed as a transition: it is a job.
- Every job has its own use case (trigger = job), is idempotent and records
  its outcome in the database.
- Concurrency strategy and failure behavior are stated.
- Stored derived values are tagged *photo figée* or *recalculable*.

## Related data skills

Cite and use these alongside the philosophy:

| Skill | Use it for |
|---|---|
| `speckit-data-mcd` | Clarify the conceptual model (MCD) and before/after diagrams of a data change |
| `data-projection` | Report what a use case does to the data (schema view + effect view) before writing it |
| `sql-migration-guidelines` | Database-first migrations: constraints, FKs, comments, timestamps, triggers, ORM-generated SQL review |
| `model-tenant-agency-user-db` | Multi-tenant ownership, RLS and scoping when the domain needs it |
| `drizzle-pg-boss` | Enqueue jobs in the same Drizzle transaction, idempotent workers |
| `fp-ts-validation` | Validate inputs at the boundary before the transaction |

## Anti-patterns

- Calling an external API inside the transaction "because it's fast".
- An endpoint that writes and then enqueues in a second, separate transaction.
- Business invariants enforced only in application code.
- An ORM abstraction that hides constraints, so the migration silently lacks
  them.
- Specs written as forms or endpoints with no initial/final state.
