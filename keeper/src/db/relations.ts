import { relations } from 'drizzle-orm'

import { blocks, events, requests } from './schema'

export const blocksRelations = relations(blocks, ({ many }) => ({
  events: many(events),
}))

export const eventsRelations = relations(events, ({ one }) => ({
  block: one(blocks, {
    fields: [events.block_number, events.chain_id],
    references: [blocks.number, blocks.chain_id],
  }),
  /** Present when this chain event was materialized into domain state. */
  request: one(requests, {
    fields: [events.id],
    references: [requests.event_id],
  }),
}))

export const requestsRelations = relations(requests, ({ one }) => ({
  event: one(events, {
    fields: [requests.event_id],
    references: [events.id],
  }),
}))
