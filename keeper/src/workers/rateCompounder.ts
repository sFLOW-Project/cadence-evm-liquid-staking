import { getCadenceClient } from '../cadence/client'
import { Env } from '../config'
import { logger } from '../utils/logger'

/// Periodically compounds Flow staking rewards into `LiquidStaking.totalFlowStaked` and
/// re-syncs the FLOW/sFLOW backing onto `LSPVault` (`RelayerRouter.compoundAndSyncRate()`),
/// keeping the EVM-side exchange rate (`getRate`, `getSFlowQuote`, `getFlowQuote`) current.
export class RateCompounder {
  private running = false
  private stopSignal = false
  private cadence: ReturnType<typeof getCadenceClient> | null = null

  constructor(private readonly env: Env) {}

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

    logger.info('Rate compounder started', {
      intervalMs: this.env.compoundPollIntervalMs,
    })

    while (!this.stopSignal) {
      try {
        await this.tick()
      } catch (error) {
        logger.error('Rate compounder tick failed', {
          error: error instanceof Error ? error.message : String(error),
        })
      }
      await this.sleep(this.env.compoundPollIntervalMs)
    }

    this.running = false
  }

  async stop(): Promise<void> {
    this.stopSignal = true
  }

  private async tick(): Promise<void> {
    const cadence = this.getCadence()
    logger.info('Compounding rewards and syncing backing')

    try {
      await cadence.compoundAndSyncRate()
    } catch (error) {
      logger.error('Compound and sync rate transaction failed', {
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }
}
