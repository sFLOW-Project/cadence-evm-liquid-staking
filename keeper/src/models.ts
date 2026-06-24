import { LogParams } from 'ethers'

export interface Contract {
  address: string
  chain_id: number
  starting_block: number
}

export type BlockParams = {
  number: number
  hash: string
  timestamp: string
  chain_id: number
}

export interface LogWithTimestamp extends LogParams {
  chainId: number
  blockTimestamp: number
}

export interface EventDTO {
  address: string
  chainId: number
  blockTimestamp: number
  eventType: string
  contractType: string
  eventData: any
}
