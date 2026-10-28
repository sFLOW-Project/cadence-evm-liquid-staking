import { JsonRpcProvider, Provider } from 'ethers'
import { Env } from './config'
import { getEventTopicHashes } from './events/decoder'
import { logger, loggerHelpers } from './utils/logger'
import { getContracts } from './db/data/contracts'
import { getLatestBlock } from './db/data/blocks'
import { LogWithTimestamp } from './models'
import { LogBatch } from './exporter'

export function createEventPoller(config: Env): EventPoller {
  return new EventPoller(config)
}

export class EventPoller {
  private provider: Provider
  private isRunning = false
  private stopSignal = false
  private retryAttempts = 0
  private lastProcessedBlock = 0
  private addressesToFilter: string[] = []
  private eventTopics: string[] = []
  private chainId = 0
  private readonly pollInterval = 10_000
  private readonly pollBlockRange = 10_000
  private readonly minBlockRange = 1
  private readonly blockRangeDivisor = 10
  private readonly blockConfirmations = 1
  private readonly maxRetryAttempts = 5
  private readonly retryDelay = 10_000
  private readonly startBlock: number
  private readonly dbUrl: string

  constructor(env: Env) {
    this.provider = new JsonRpcProvider(env.evmRpcUrl)
    this.startBlock = env.startBlock
    this.dbUrl = env.dbUrl
    this.eventTopics = getEventTopicHashes()
  }

  getChainId(): number {
    return this.chainId
  }

  async *start(startBlock?: number | null): AsyncGenerator<LogBatch> {
    if (this.isRunning) {
      logger.warn('Adapter is already running')
      return
    }

    this.isRunning = true
    this.stopSignal = false
    this.chainId = Number(
      await this.provider.getNetwork().then((network) => network.chainId)
    )

    const contracts = await getContracts(this.dbUrl, this.chainId)
    if (!contracts || contracts.length === 0) {
      throw new Error('No contracts found')
    }

    this.addressesToFilter = contracts
      .map((contract) => contract.address)
      .filter((addr) => addr && addr.startsWith('0x') && addr.length === 42)

    logger.info('RPC adapter initialized', {
      addressesToFilter: this.addressesToFilter,
      eventTopics: this.eventTopics.length,
    })

    const lastProcessedBlock = await this.loadLastProcessedBlock()
    let fromBlock =
      startBlock ?? (lastProcessedBlock != null ? lastProcessedBlock + 1 : null) ?? this.startBlock

    if (!fromBlock) {
      throw new Error('No starting block found')
    }

    logger.info(`Starting polling from block ${fromBlock}`)

    for await (const batch of this.pollFilteredLogs(fromBlock)) {
      yield batch
      this.lastProcessedBlock = batch.endBlock
    }
  }

  async stop(): Promise<void> {
    logger.info('Stopping Poller...')
    this.stopSignal = true
    this.isRunning = false

    if (this.lastProcessedBlock) {
      logger.info('Final state saved', {
        lastProcessedBlock: this.lastProcessedBlock.toString(),
      })
    }
  }

  private async *pollFilteredLogs(
    block: number
  ): AsyncGenerator<LogBatch> {
    while (!this.stopSignal && this.retryAttempts <= this.maxRetryAttempts) {
      try {
        const safeLatestBlock =
          (await this.getLatestBlockNumber()) - this.blockConfirmations
        if (block <= safeLatestBlock) {
          const maxEndBlock = Math.min(
            block + this.pollBlockRange - 1,
            safeLatestBlock
          )
          let currentRange = maxEndBlock - block + 1
          let lastError: Error | null = null

          while (currentRange >= this.minBlockRange) {
            const endBlock = block + currentRange - 1
            logger.info('Processing block range:', {
              fromBlock: block,
              toBlock: endBlock,
              range: currentRange,
              safeLatestBlock,
            })
            try {
              const logs = await this.provider.getLogs({
                fromBlock: block,
                toBlock: endBlock,
                address: this.addressesToFilter,
                topics: [this.eventTopics],
              })

              logger.info('Block range processing completed:', {
                fromBlock: block,
                toBlock: endBlock,
                logsFound: logs.length,
              })

              const uniqueBlockNumbers = [
                ...new Set(logs.map((l) => l.blockNumber)),
              ]
              const blockMap = new Map<
                number,
                Awaited<ReturnType<Provider['getBlock']>>
              >()
              const getBlockConcurrency = 20
              for (
                let i = 0;
                i < uniqueBlockNumbers.length;
                i += getBlockConcurrency
              ) {
                const chunk = uniqueBlockNumbers.slice(
                  i,
                  i + getBlockConcurrency
                )
                const blocks = await Promise.all(
                  chunk.map((num) => this.provider.getBlock(num))
                )
                chunk.forEach((num, j) => blockMap.set(num, blocks[j]))
                if (i + getBlockConcurrency < uniqueBlockNumbers.length) {
                  await this.sleep(50)
                }
              }

              const logsWithBlockTimestamp: LogWithTimestamp[] = logs.map(
                (log) => {
                  const blockData = blockMap.get(log.blockNumber)
                  return {
                    address: log.address,
                    blockHash: blockData?.hash ?? log.blockHash,
                    blockNumber: log.blockNumber,
                    data: log.data,
                    index: log.index,
                    removed: log.removed,
                    topics: [...log.topics],
                    transactionHash: log.transactionHash,
                    transactionIndex: log.transactionIndex,
                    chainId: this.chainId,
                    blockTimestamp: blockData?.timestamp ?? 0,
                  }
                }
              )

              yield { logs: logsWithBlockTimestamp, endBlock }

              block = endBlock + 1
              await this.sleep(1000)
              break
            } catch (error) {
              lastError = error as Error
              const err = lastError as Error & { code?: string }
              loggerHelpers.logError('retrieving block logs', err, {
                fromBlock: block,
                toBlock: endBlock,
                range: currentRange,
                lastProcessedBlock: this.lastProcessedBlock,
                errorMessage: err?.message,
                errorCode: err?.code,
              })
              if (currentRange <= this.minBlockRange) {
                throw lastError
              }
              currentRange = Math.max(
                this.minBlockRange,
                Math.floor(currentRange / this.blockRangeDivisor)
              )
              logger.info('Retrying with smaller block range', {
                newRange: currentRange,
                fromBlock: block,
              })
              await this.sleep(500)
            }
          }
        } else {
          logger.info(
            `No new blocks available, sleeping ${this.pollInterval}ms`,
            {
              lastProcessedBlock: this.lastProcessedBlock,
              safeLatestBlock,
            }
          )

          await this.sleep(this.pollInterval)
        }
      } catch (error) {
        loggerHelpers.logError(
          'Failed to poll for new blocks:',
          error as Error,
          {
            lastProcessedBlock: this.lastProcessedBlock,
            retryAttempts: this.retryAttempts,
            retryDelay: this.retryDelay,
          }
        )
        this.retryAttempts++
        await this.sleep(this.retryDelay)
      }
    }
    if (this.stopSignal) {
      return
    }
    throw new Error('All retry attempts failed')
  }

  private async getLatestBlockNumber(): Promise<number> {
    try {
      const blockNumber = await this.provider.getBlockNumber()
      logger.debug('Retrieved latest block number', {
        blockNumber: blockNumber.toString(),
      })
      return blockNumber
    } catch (error) {
      loggerHelpers.logError('getting latest block number', error as Error)
      throw error
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }

  private async loadLastProcessedBlock(): Promise<number | null> {
    try {
      const block = await getLatestBlock(this.dbUrl, this.chainId)
      if (!block) {
        return null
      }
      logger.info(`Last processed block loaded: ${block.number}`)
      return block.number
    } catch (error) {
      loggerHelpers.logError(
        'Failed to load saved state. Reason:',
        error as Error
      )
      return null
    }
  }
}
