import {
  pgTable,
  text,
  timestamp,
  foreignKey,
  integer,
  json,
  primaryKey,
  uniqueIndex,
} from 'drizzle-orm/pg-core'

export const contracts = pgTable(
  'contracts',
  {
    address: text('address').notNull(),
    chain_id: integer('chain_id').notNull(),
    starting_block: integer('starting_block').notNull().default(0),
  },
  (table) => {
    return [
      primaryKey({
        columns: [table.address, table.chain_id],
        name: 'contracts_pkey',
      }),
    ]
  }
)

export const blocks = pgTable(
  'blocks',
  {
    number: integer('number').notNull(),
    hash: text('hash').notNull(),
    timestamp: timestamp('timestamp', {
      withTimezone: true,
      mode: 'string',
    }).notNull(),
    chain_id: integer('chain_id').notNull(),
  },
  (table) => {
    return [
      primaryKey({
        columns: [table.number, table.chain_id],
        name: 'blocks_pkey',
      }),
    ]
  }
)

export const events = pgTable(
  'events',
  {
    id: text('id').primaryKey().notNull(),
    chain_id: integer('chain_id').notNull(),
    block_number: integer('block_number').notNull(),
    transaction_hash: text('transaction_hash').notNull(),
    log_index: integer('log_index').notNull(),
    event: text('event').notNull(),
    data: json('data').notNull(),
    timestamp: timestamp('timestamp', { withTimezone: true, mode: 'string' }),
    processed_at: timestamp('processed_at', {
      withTimezone: true,
      mode: 'string',
    }),
    received_at: timestamp('received_at', {
      withTimezone: true,
      mode: 'string',
    }).notNull(),
  },
  (table) => [
    foreignKey({
      columns: [table.block_number, table.chain_id],
      foreignColumns: [blocks.number, blocks.chain_id],
      name: 'events_block_number_chain_id_fkey',
    }).onDelete('cascade'),
  ]
)

export const requests = pgTable(
  'requests',
  {
    id: text('id').notNull(),
    type: text('type').notNull(),
    version: integer('version').notNull(),
    chain_id: integer('chain_id').notNull(),
    event_id: text('event_id')
      .notNull()
      .references(() => events.id, { onDelete: 'cascade' }),
    requester: text('requester').notNull(),
    status: text('status').notNull(),
    data: json('data').notNull(),
    created_at: timestamp('created_at').notNull(),
    updated_at: timestamp('updated_at').notNull(),
  },
  (table) => [
    primaryKey({
      columns: [table.id, table.version],
      name: 'requests_pkey',
    }),
    uniqueIndex('requests_event_id_uidx').on(table.event_id),
  ]
)
