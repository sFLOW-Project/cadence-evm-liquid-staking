import { LogWithTimestamp } from '../models'

export type VaultEventName =
  | 'StakeRequested'
  | 'StakeCancelled'
  | 'StakeFulfilled'
  | 'UnstakeRequested'
  | 'UnstakeConfirmed'
  | 'UnstakeFulfilled'
  | 'UnstakeCancelled'
  | 'WithdrawalClaimed'
  | 'BackingUpdated'
  | 'ConfigUpdated'
  | 'MinRequestAmountUpdated'
  | 'IsStakingPausedUpdated'
  | 'IsUnstakingPausedUpdated'
  | 'ProtocolFeeUpdated'
  | 'SlippageToleranceUpdated'

export type ParsedVaultEvent = {
  eventId: string
  log: LogWithTimestamp
  name: VaultEventName
  args: Record<string, unknown>
}
