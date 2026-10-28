import { getCadenceClient } from './cadence/client'
import { Env } from './config'
import { createBlock, getLatestBlock } from './db/data/blocks'
import {
  getEventById,
  insertEvent,
  markEventProcessed,
} from './db/data/events'
import { getCachedDb } from './db'
import { decodeVaultLog } from './events/decoder'
import { dispatchEvent, hasHandler } from './events/router'
import { HandlerContext } from './events/handlers/context'
import { LogWithTimestamp } from './models'
import { logger } from './utils/logger'

export type LogBatch = {
  logs: LogWithTimestamp[]
  endBlock: number
}

export function createEventExporter(config: Env): EventExporter {
  return new PgEventExporter(config)
}

export abstract class EventExporter {
  abstract publishBatch(batch: LogBatch): Promise<void>
  abstract stop(): Promise<void>
}

class PgEventExporter extends EventExporter {
  private cadence: ReturnType<typeof getCadenceClient> | null = null
  private chainId = 0

  constructor(private readonly config: Env) {
    super()
  }

  private getCadence() {
    if (!this.cadence) {
      this.cadence = getCadenceClient(this.config)
    }
    return this.cadence
  }

  async publishBatch(batch: LogBatch): Promise<void> {
    if (batch.logs.length === 0) {
      await this.checkpointBlocks(batch.logs, batch.endBlock)
      return
    }

    this.chainId = batch.logs[0].chainId

    for (const log of batch.logs) {
      await this.processLog(log)
    }

    await this.checkpointBlocks(batch.logs, batch.endBlock)
  }

  private async processLog(log: LogWithTimestamp): Promise<void> {
    const parsed = decodeVaultLog(log)
    if (!parsed) {
      logger.warn('Skipping undecodable log', {
        txHash: log.transactionHash,
        logIndex: log.index,
      })
      return
    }

    const existing = await getEventById(this.config.dbUrl, parsed.eventId)
    if (existing) {
      logger.debug('Skipping duplicate event', { eventId: parsed.eventId })
      return
    }

    const db = getCachedDb(this.config.dbUrl)
    const blockTimestamp = log.blockTimestamp
      ? new Date(log.blockTimestamp * 1000).toISOString()
      : null

    try {
      await db.transaction(async (tx) => {
        await createBlock(
          this.config.dbUrl,
          {
            number: log.blockNumber,
            hash: log.blockHash ?? '',
            timestamp: blockTimestamp ?? new Date().toISOString(),
            chain_id: log.chainId,
          },
          tx
        )

        const inserted = await insertEvent(
          this.config.dbUrl,
          {
            id: parsed.eventId,
            chain_id: log.chainId,
            block_number: log.blockNumber,
            transaction_hash: log.transactionHash,
            log_index: log.index,
            event: parsed.name,
            data: parsed.args,
            timestamp: blockTimestamp,
            processed_at: null,
            received_at: new Date().toISOString(),
          },
          tx
        )

        if (!inserted) return

        const ctx: HandlerContext = {
          dbUrl: this.config.dbUrl,
          chainId: log.chainId,
          cadence: this.getCadence(),
          env: this.config,
          tx,
        }

        if (hasHandler(parsed.name)) {
          await dispatchEvent(ctx, parsed)
        }

        await markEventProcessed(this.config.dbUrl, parsed.eventId, tx)
      })
    } catch (error) {
      logger.error('Failed to process event', {
        eventId: parsed.eventId,
        event: parsed.name,
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  private async checkpointBlocks(
    logs: LogWithTimestamp[],
    endBlock: number
  ): Promise<void> {
    const seen = new Set<number>()
    for (const log of logs) {
      if (seen.has(log.blockNumber)) continue
      seen.add(log.blockNumber)
      await createBlock(this.config.dbUrl, {
        number: log.blockNumber,
        hash: log.blockHash ?? '',
        timestamp: log.blockTimestamp
          ? new Date(log.blockTimestamp * 1000).toISOString()
          : new Date().toISOString(),
        chain_id: log.chainId,
      })
    }

    const chainId = logs[0]?.chainId ?? this.chainId
    if (chainId) {
      const block = await getLatestBlock(this.config.dbUrl, chainId)
      if (!block || block.number < endBlock) {
        await createBlock(this.config.dbUrl, {
          number: endBlock,
          hash: 'checkpoint',
          timestamp: new Date().toISOString(),
          chain_id: chainId,
        })
      }
    }
  }

  async stop(): Promise<void> {}
}
