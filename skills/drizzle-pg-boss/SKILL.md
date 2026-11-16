---
name: drizzle-pg-boss
description: >-
  Enqueue pg-boss jobs atomically inside a Drizzle ORM transaction on
  PostgreSQL with the built-in `fromDrizzle` adapter (pg-boss >= 12.17.0), and
  write idempotent workers that run their own Drizzle transaction. Use when a
  use case must write business rows and schedule async or external work
  (emails, API calls, webhooks) in one commit, when wiring pg-boss into a
  Drizzle codebase, reviewing insert-then-send code that can lose or duplicate
  jobs, or configuring queues (retries, dead letter, schedules, shutdown).
---

# Drizzle x pg-boss

Make "write the data" and "schedule the follow-up work" one atomic commit:
pg-boss stores jobs in PostgreSQL, so the job insert can share the business
transaction. Both exist or neither does (principle 3 of `philosophy-data-first`).

## Templates

- `templates/enqueue-in-tx.ts` - `boss.send(..., { db: fromDrizzle(tx, sql) })`
  inside `db.transaction`.
- `templates/worker.ts` - bootstrap, queue with retry and dead letter,
  idempotent worker with its own transaction, graceful shutdown.

## Facts to keep in mind

- `fromDrizzle` ships in `pg-boss` >= 12.17.0. Pass Drizzle's `sql` tag as the
  second argument. Supported drivers: node-postgres, postgres-js, bun-sql.
- Pin pg-boss with `--save-exact`: queue option names change between minors.
- ESM-only; `PgBoss` is a named export.
- Call `boss.start()` before anything else, and create the dead-letter queue
  too. Retention options are in seconds (`retentionSeconds`,
  `deleteAfterSeconds`); there is no `retentionDays`.
- Recurring work: `boss.schedule(name, cron, data, { tz })` (UTC by default).
- pg-boss owns its schema (`pgboss` by default): never declare it in the
  Drizzle schema and exclude it from `drizzle-kit`.
- Handlers receive an array of jobs, even with `batchSize: 1`.
- Delivery is at least once. The handler checks state first, the external call
  carries an idempotency key, and the outcome (`PENDING -> SENT | FAILED`) is
  written to the database. A business unique constraint is the primary
  dedup guard; `singletonKey` is throttling, not exactly-once.

## Anti-pattern

```ts
await db.insert(orders).values(input)          // commit #1
await boss.send('order.send-receipt', payload) // commit #2, may never happen
```

A crash between the two loses the job; sending first emails for a rolled-back
order.

## Review checklist

- Every `boss.send` after a business write is inside the same transaction with
  `{ db: fromDrizzle(tx, sql) }`.
- No network call inside a Drizzle transaction callback.
- Handlers are idempotent and record their outcome in the database.
- Queues are created explicitly with retry and dead-letter settings.
- Shutdown stops pg-boss before closing the pool.

## Related skills

`philosophy-data-first`, `sql-migration-guidelines` (unique keys, status
`CHECK`s), `data-projection`.
