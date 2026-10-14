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

# Drizzle × pg-boss

## Purpose

Make "write the data" and "schedule the follow-up work" a single atomic
commit. pg-boss stores jobs in PostgreSQL, so a job insert can share the
business transaction: either both the rows and the job exist, or neither does.
This is the implementation of principle 3 of the `philosophy-data-first`
skill.

Reference tutorial: [Drizzle ORM + pg-boss: atomic transactions](https://nerdleveltech.com/drizzle-orm-pg-boss-atomic-transactions-tutorial).

## Versions

- `pg-boss` **>= 12.17.0** — first version exporting `fromDrizzle` (with
  `fromKnex`, `fromKysely`, `fromPrisma`…). Pin it with `--save-exact`: queue
  option names change between minors.
- `drizzle-orm` with the `node-postgres` (`pg`) driver.
- pg-boss is ESM-only and exports `PgBoss` as a **named** export.

## The pattern

```ts
import { PgBoss, fromDrizzle } from 'pg-boss'
import { sql } from 'drizzle-orm'

await db.transaction(async (tx) => {
  const [order] = await tx
    .insert(orders)
    .values(input)
    .returning({ id: orders.id })

  await boss.send(
    'order.send-receipt',
    { orderId: order.id },
    { db: fromDrizzle(tx, sql) }, // job insert goes through `tx`
  )
})
```

- `fromDrizzle(tx, sql)` wraps the Drizzle transaction as a pg-boss
  `IDatabase`; pass Drizzle's `sql` tag, not a raw string.
- If anything throws, the transaction rolls back **and the job disappears**.
- No external I/O inside the callback: no `fetch`, no email, no third-party
  SDK call. That is what the job is for.

### Anti-pattern this replaces

```ts
await db.insert(orders).values(input)          // commit #1
await boss.send('order.send-receipt', payload) // commit #2 — may never happen
```

A crash between the two leaves an order without its email; sending before the
insert gives an email for an order that rolled back.

## Bootstrap and shutdown

```ts
const boss = new PgBoss(process.env.DATABASE_URL!)
boss.on('error', console.error)
await boss.start()                 // first: runs pg-boss's own migrations
await boss.createQueue('order.send-receipt', {
  retryLimit: 5,
  retryDelay: 30,
  retryBackoff: true,
  expireInSeconds: 900,
  deadLetter: 'order.send-receipt.dlq',
})

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.once(signal, async () => {
    await boss.stop({ graceful: true, timeout: 30_000 })
    await pool.end()
  })
}
```

- Call `start()` before any other method; create the dead-letter queue too.
- Retention option names are in **seconds** (`retentionSeconds`,
  `deleteAfterSeconds`); there is no `retentionDays`.
- Recurring work: `boss.schedule(name, cron, data, { tz })` (UTC by default).
- pg-boss owns its own schema (`pgboss` by default): never declare those
  tables in the Drizzle schema, and exclude that schema from `drizzle-kit`.

## Workers

```ts
await boss.work<{ orderId: string }>(
  'order.send-receipt',
  { batchSize: 1 },
  async ([job]) => {                               // handler receives an array
    const order = await db.query.orders.findFirst({
      where: eq(orders.id, job.data.orderId),
    })
    if (!order || order.receiptStatus === 'SENT') return // idempotent

    await mailer.send(order, { idempotencyKey: order.id }) // external I/O, outside tx

    await db.transaction(async (tx) => {
      await tx.update(orders)
        .set({ receiptStatus: 'SENT' })
        .where(eq(orders.id, order.id))
      // follow-up jobs: same pattern, { db: fromDrizzle(tx, sql) }
    })
  },
)
```

- Delivery is **at least once**: a job can run twice (crash after the
  external call, expiry, retry). The handler checks state first and the
  external call carries an idempotency key derived from the data.
- The job's outcome is written to the database (`PENDING → SENT | FAILED`),
  so it is visible without querying pg-boss.
- Throwing marks the job failed and triggers the retry policy; after the
  last retry the payload goes to `deadLetter`.
- Deduplication: a business unique constraint is the primary guard;
  `singletonKey` / queue policies are throttling aids, not a guarantee of
  exactly-once.

## Review checklist

- [ ] Every `boss.send` that follows a business write is inside the same
      `db.transaction` with `{ db: fromDrizzle(tx, sql) }`.
- [ ] No network call inside a Drizzle transaction callback.
- [ ] Every handler is idempotent and records its outcome in the database.
- [ ] Queues are created explicitly with retry and dead-letter settings.
- [ ] `pg-boss` version is pinned and >= 12.17.0.
- [ ] Graceful shutdown stops pg-boss before closing the pool.

## Related skills

- `philosophy-data-first` — why use cases are transactions and side effects
  are jobs.
- `sql-migration-guidelines` — constraints that make handlers idempotent
  (unique keys, status `CHECK`s).
- `data-projection` — report what a use case and its jobs do to the data.
