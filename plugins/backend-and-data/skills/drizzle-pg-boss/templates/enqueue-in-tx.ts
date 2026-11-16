// Atomic "write rows + schedule work": the job insert joins the Drizzle transaction.
// Requires pg-boss >= 12.17.0 (pinned exactly), drizzle-orm with node-postgres.
import { fromDrizzle } from 'pg-boss'
import { sql } from 'drizzle-orm'
import { db } from './db' // your Drizzle instance
import { boss } from './boss' // started PgBoss instance (see worker.ts)
import { orders } from './schema'

export async function placeOrder(input: typeof orders.$inferInsert) {
  return db.transaction(async (tx) => {
    const [order] = await tx
      .insert(orders)
      .values({ ...input, receiptStatus: 'PENDING' })
      .returning({ id: orders.id })

    // Goes through `tx`: if the transaction rolls back, the job disappears.
    await boss.send(
      'order.send-receipt',
      { orderId: order.id },
      { db: fromDrizzle(tx, sql) },
    )

    // No fetch / email / SDK call here: that is the worker's job.
    return order
  })
}
