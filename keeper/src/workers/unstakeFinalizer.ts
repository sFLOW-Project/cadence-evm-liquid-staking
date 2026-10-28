import { getCadenceClient } from '../cadence/client'
import { Env } from '../config'
import { getUnstakesAwaitingFinalize } from '../db/data/requests'
import { logger } from '../utils/logger'

export class UnstakeFinalizer {
  private running = false
  private stopSignal = false
  private cadence: ReturnType<typeof getCadenceClient> | null = null

  constructor(
    private readonly env: Env,
    private readonly chainId: number
  ) {}

  private getCadence() {
    if (!this.cadence) {
      this.cadence = getCadenceClient(this.env)
    }
    return this.cadence
  }

  async start(): Promise<void> {
    if (this.running) return
    this.running = true
    this.stopSignal = false

    logger.info('Unstake finalizer started', {
      intervalMs: this.env.finalizePollIntervalMs,
    })

    while (!this.stopSignal) {
      try {
        await this.tick()
      } catch (error) {
        logger.error('Unstake finalizer tick failed', {
          error: error instanceof Error ? error.message : String(error),
        })
      }
      await this.sleep(this.env.finalizePollIntervalMs)
    }

    this.running = false
  }

  async stop(): Promise<void> {
    this.stopSignal = true
  }

  private async tick(): Promise<void> {
    const pending = await getUnstakesAwaitingFinalize(
      this.env.dbUrl,
      this.chainId
    )
    if (pending.length === 0) return

    const cadence = this.getCadence()
    const [currentEpoch, delay] = await Promise.all([
      cadence.getCurrentEpoch(),
      cadence.getUnstakeUnlockEpochDelay(),
    ])

    const ready = pending.filter((req) => {
      const unlockEpoch = BigInt(req.data.unlockEpoch ?? '0')
      return currentEpoch >= unlockEpoch + delay
    })

    if (ready.length === 0) {
      logger.debug('No unstakes ready to finalize', {
        pending: pending.length,
        currentEpoch: currentEpoch.toString(),
      })
      return
    }

    const ids = ready.map((r) => r.id)
    logger.info('Finalizing unstakes', { ids, count: ids.length })

    try {
      await cadence.finalizeUnstakes(ids)
    } catch (error) {
      logger.error('Finalize unstakes transaction failed', {
        ids,
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }
}
