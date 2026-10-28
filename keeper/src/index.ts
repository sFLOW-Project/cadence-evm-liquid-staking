import { JsonRpcProvider } from 'ethers'

import { Env, getEnv } from './config'
import { createEventPoller, EventPoller } from './poller'
import { createEventExporter, EventExporter } from './exporter'
import { UnstakeFinalizer } from './workers/unstakeFinalizer'
import { RateCompounder } from './workers/rateCompounder'
import { logger } from './utils/logger'

class Indexer {
  private poller: EventPoller
  private exporter: EventExporter
  private finalizer: UnstakeFinalizer
  private compounder: RateCompounder

  constructor(
    private readonly config: Env,
    chainId: number
  ) {
    try {
      this.poller = createEventPoller(config)
      this.exporter = createEventExporter(config)
      this.finalizer = new UnstakeFinalizer(config, chainId)
      this.compounder = new RateCompounder(config)
      logger.info('Indexer successfully initialized')
    } catch (error) {
      logger.error('Failed to initialize indexer:', error)
      throw error
    }
  }

  async start(startBlock?: number | null) {
    logger.info('Starting keeper...')

    void this.finalizer.start()
    void this.compounder.start()

    try {
      for await (const batch of this.poller.start(startBlock)) {
        await this.exporter.publishBatch(batch)
      }
    } catch (error) {
      logger.error('Error during polling:', error)
      await this.stop()
      throw error
    }
  }

  async stop() {
    logger.info('Stopping keeper...')
    try {
      await this.finalizer.stop()
      await this.compounder.stop()
      await this.poller.stop()
      await this.exporter.stop()
      logger.info('Keeper stopped successfully')
    } catch (error) {
      logger.error('Error stopping keeper:', error)
      throw error
    }
  }
}

async function main() {
  const config = getEnv()
  const provider = new JsonRpcProvider(config.evmRpcUrl)
  const chainId = Number(
    await provider.getNetwork().then((network) => network.chainId)
  )

  const indexer = new Indexer(config, chainId)

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

  await indexer.start(config.startBlock)
  logger.info('Keeper is running.')
}

main().catch((err) => {
  logger.error('Failed to start keeper:', err)
  process.exit(1)
})
