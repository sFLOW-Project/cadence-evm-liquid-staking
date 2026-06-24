import { Env, getEnv } from './config'
import { createEventPoller, EventPoller } from './poller'
import { createEventExporter, EventExporter } from './exporter'
import { logger } from './utils/logger'

class Indexer {
  private poller: EventPoller
  private exporter: EventExporter

  constructor(private readonly config: Env) {
    try {
      this.poller = createEventPoller(config)
      this.exporter = createEventExporter(config)
      logger.info('Indexer successfully initialized')
    } catch (error) {
      logger.error('Failed to initialize indexer:', error)
      throw error
    }
  }

  async start(startBlock?: number | null) {
    logger.info('Starting Ethereum Event Indexer...')

    try {
      // Start the poller with optional start block
      for await (const log of this.poller.start(startBlock)) {
        await this.exporter.publishEvent(log)
      }
    } catch (error) {
      logger.error('Error during polling:', error)
      await this.poller.stop()
      throw error
    }
  }

  async stop() {
    logger.info('Stopping keeper...')
    try {
      await this.poller.stop()
      logger.info('Keeper stopped successfully')
    } catch (error) {
      logger.error('Error stopping keeper:', error)
      throw error
    }
  }
}

// Get validated configuration
const config = getEnv()

// Create and start indexer
const indexer = new Indexer(config)

// Graceful shutdown handlers
const shutdown = async (signal: string) => {
  logger.info(`Received ${signal}, shutting down gracefully...`)
  try {
    await indexer.stop()
    process.exit(0)
  } catch (error) {
    logger.error('Error during shutdown:', error)
    process.exit(1)
  }
}
process.on('SIGINT', () => shutdown('SIGINT'))
process.on('SIGTERM', () => shutdown('SIGTERM'))

indexer
  .start(config.startBlock)
  .then(() => logger.info('Keeper is running.'))
  .catch((err) => {
    logger.error('Failed to start keeper:', err)
    process.exit(1)
  })
