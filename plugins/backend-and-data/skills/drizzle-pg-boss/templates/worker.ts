// pg-boss bootstrap, queue definition, idempotent worker, graceful shutdown.
// pg-boss is ESM-only and exports PgBoss as a named export.
import { PgBoss, fromDrizzle } from 'pg-boss'
import { eq, sql } from 'drizzle-orm'
import { db, pool } from './db'
import { orders } from './schema'
import { mailer } from './mailer'

export const boss = new PgBoss(process.env.DATABASE_URL!)
boss.on('error', console.error)

const QUEUE = 'order.send-receipt'

export async function startWorkers() {
  await boss.start() // first call: runs pg-boss's own migrations
  await boss.createQueue(`${QUEUE}.dlq`)
  await boss.createQueue(QUEUE, {
    retryLimit: 5,
    retryDelay: 30,
    retryBackoff: true,
    expireInSeconds: 900,
    deadLetter: `${QUEUE}.dlq`,
  })

  await boss.work<{ orderId: string }>(QUEUE, { batchSize: 1 }, async ([job]) => {
    const order = await db.query.orders.findFirst({
      where: eq(orders.id, job.data.orderId),
    })
    // Delivery is at least once: check state first.
    if (!order || order.receiptStatus === 'SENT') return

    // External I/O stays outside any transaction; key derived from the data.
    await mailer.send(order, { idempotencyKey: order.id })

    // The worker's own Drizzle transaction records the outcome.
    await db.transaction(async (tx) => {
      await tx
        .update(orders)
        .set({ receiptStatus: 'SENT' })
        .where(eq(orders.id, order.id))
      // Follow-up jobs: await boss.send(name, data, { db: fromDrizzle(tx, sql) })
    })
    // Throwing instead triggers the retry policy, then the dead-letter queue.
  })

  for (const signal of ['SIGTERM', 'SIGINT'] as const) {
    process.once(signal, async () => {
      await boss.stop({ graceful: true, timeout: 30_000 }) // stop pg-boss first
      await pool.end()
    })
  }
}
