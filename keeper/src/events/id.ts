import { LogWithTimestamp } from '../models'

export function buildEventId(log: LogWithTimestamp): string {
  return `${log.chainId}:${log.blockNumber}:${log.transactionHash}:${log.index}`
}
