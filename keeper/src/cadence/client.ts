import { readFileSync } from 'fs'
import { join } from 'path'

import * as fcl from '@onflow/fcl'

import { CadenceEnv } from '../config'
import { logger } from '../utils/logger'
import { configureFcl } from './config'
import { createPayerAuthz } from './auth'

const CADENCE_ROOT = join(process.cwd(), 'src', 'cadence')
const FLOW_ATTEMPTS = 5
const FLOW_RETRY_DELAY_MS = 2_000
const TX_POLL_INTERVAL_MS = 2_000
const TX_SEAL_TIMEOUT_MS = 120_000

function loadCdc(relativePath: string): string {
  return readFileSync(join(CADENCE_ROOT, relativePath), 'utf8')
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function withFlowRetry<T>(
  operation: string,
  fn: () => Promise<T>
): Promise<T> {
  let lastError: unknown

  for (let attempt = 1; attempt <= FLOW_ATTEMPTS; attempt++) {
    try {
      return await fn()
    } catch (error) {
      lastError = error
      if (attempt < FLOW_ATTEMPTS) {
        logger.warn('Retrying Flow operation', {
          operation,
          attempt,
          nextAttempt: attempt + 1,
          error: error instanceof Error ? error.message : String(error),
        })
        await sleep(FLOW_RETRY_DELAY_MS * attempt)
      }
    }
  }

  throw lastError
}

export class CadenceClient {
  private readonly authz: ReturnType<typeof createPayerAuthz>

  constructor(private readonly env: CadenceEnv) {
    configureFcl(env)
    this.authz = createPayerAuthz(env)
  }

  async handleStakes(stakeRequestIds: string[]): Promise<string> {
    return this.sendTransaction('transactions/handle_stakes.cdc', (arg, t) => [
      arg(
        stakeRequestIds.map((id) => id),
        t.Array(t.UInt256)
      ),
      arg(this.env.maxBridgeFlowFee, t.UFix64),
    ])
  }

  async initiateUnstakes(unstakeRequestIds: string[]): Promise<string> {
    return this.sendTransaction(
      'transactions/initiate_unstakes.cdc',
      (arg, t) => [
        arg(
          unstakeRequestIds.map((id) => id),
          t.Array(t.UInt256)
        ),
        arg(this.env.maxBridgeFlowFee, t.UFix64),
      ]
    )
  }

  async finalizeUnstakes(unstakeRequestIds: string[]): Promise<string> {
    return this.sendTransaction(
      'transactions/finalize_unstakes.cdc',
      (arg, t) => [
        arg(
          unstakeRequestIds.map((id) => id),
          t.Array(t.UInt256)
        ),
      ]
    )
  }

  async compoundAndSyncRate(): Promise<string> {
    return this.sendTransaction(
      'transactions/compound_and_sync_rate.cdc',
      () => []
    )
  }

  async getCurrentEpoch(): Promise<bigint> {
    const result = await this.runScript('scripts/get_current_epoch.cdc')
    return BigInt(String(result))
  }

  async getUnstakeUnlockEpochDelay(): Promise<bigint> {
    const result = (await this.runScript(
      'scripts/get_protocol_config.cdc'
    )) as {
      delay: string
    }
    return BigInt(result.delay)
  }

  private async sendTransaction(
    cdcPath: string,
    buildArgs: (
      arg: typeof fcl.arg,
      t: typeof fcl.t
    ) => ReturnType<typeof fcl.arg>[]
  ): Promise<string> {
    const cadence = loadCdc(cdcPath)
    const submitted = await withFlowRetry(`submit ${cdcPath}`, () =>
      fcl.mutate({
        cadence,
        args: buildArgs,
        proposer: this.authz,
        payer: this.authz,
        authorizations: [this.authz],
        limit: 9999,
      })
    )
    const txId = typeof submitted === 'string' ? submitted : fcl.txId(submitted)

    logger.info('Cadence transaction submitted', { txId, cdcPath })
    await this.waitSealed(txId)
    return txId
  }

  private async runScript(cdcPath: string): Promise<unknown> {
    const cadence = loadCdc(cdcPath)
    return withFlowRetry(`query ${cdcPath}`, () => fcl.query({ cadence }))
  }

  private async waitSealed(txId: string): Promise<void> {
    const deadline = Date.now() + TX_SEAL_TIMEOUT_MS

    while (Date.now() < deadline) {
      const result = await withFlowRetry(`snapshot ${txId}`, () =>
        fcl.tx(txId).snapshot()
      )

      if (result.status === 4) {
        if (result.statusCode && result.statusCode !== 0) {
          throw new Error(
            `Transaction ${txId} sealed with statusCode ${result.statusCode}: ${result.errorMessage ?? 'unknown'}`
          )
        }
        return
      }

      if (result.errorMessage) {
        throw new Error(
          `Transaction ${txId} failed with status ${result.status}: ${result.errorMessage}`
        )
      }

      await sleep(TX_POLL_INTERVAL_MS)
    }

    const result = await fcl.tx(txId).snapshot()
    if (result.status !== 4) {
      throw new Error(
        `Timed out waiting for transaction ${txId} to seal; last status ${result.status}`
      )
    }
  }
}

let clientInstance: CadenceClient | null = null

export function getCadenceClient(env: CadenceEnv): CadenceClient {
  if (!clientInstance) {
    clientInstance = new CadenceClient(env)
  }
  return clientInstance
}
