import { eq } from 'drizzle-orm/sql'

import { getCachedDb } from '..'
import { events } from '../schema'

export type EventRow = {
  id: string
  chain_id: number
  block_number: number
  transaction_hash: string
  log_index: number
  event: string
  data: unknown
  timestamp: string | null
  processed_at: string | null
  received_at: string
}

export async function getEventById(
  dbUrl: string,
  id: string
): Promise<EventRow | null> {
  const db = getCachedDb(dbUrl)
  return (await db.query.events.findFirst({ where: eq(events.id, id) })) ?? null
}

export async function insertEvent(
  dbUrl: string,
  row: EventRow,
  tx?: any
): Promise<boolean> {
  const db = tx ?? getCachedDb(dbUrl)
  const result = await db
    .insert(events)
    .values(row)
    .onConflictDoNothing()
    .returning({ id: events.id })
  return result.length > 0
}

export async function markEventProcessed(
  dbUrl: string,
  id: string,
  tx?: any
): Promise<void> {
  const db = tx ?? getCachedDb(dbUrl)
  await db
    .update(events)
    .set({ processed_at: new Date().toISOString() })
    .where(eq(events.id, id))
}
