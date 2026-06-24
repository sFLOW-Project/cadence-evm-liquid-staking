import { LogWithTimestamp, EventDTO } from './models'

import { logger, loggerHelpers } from './utils/logger'

export function createEventExporter(
  config: EventExporterConfig
): EventExporter {
  return new PgEventExporter(config)
}

interface EventExporterConfig {
  dbUrl: string | null
}

export abstract class EventExporter {
  /**
   * Publish a single event to the queue
   */
  abstract publishEvent(log: LogWithTimestamp): Promise<void>

  abstract stop(): Promise<void>
}

class PgEventExporter extends EventExporter {
  private readonly dbUrl: string
  constructor(private readonly config: EventExporterConfig) {
    super()
    if (!config.dbUrl) {
      throw new Error('dbUrl is required')
    }
    this.dbUrl = config.dbUrl
  }

  async publishEvent(log: LogWithTimestamp): Promise<void> {
    const event = this.validate(log)
    if (!event) {
      throw new Error('Invalid event')
    }
  }

  private validate(log: LogWithTimestamp): EventDTO | null {
    throw new Error('Not implemented')
  }

  async stop(): Promise<void> {
    // No connection pool yet; keep as safe no-op for graceful shutdown.
  }
}
