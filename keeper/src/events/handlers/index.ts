import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'
import { handleStakeCancelled } from './stakeCancelled'
import { handleStakeFulfilled } from './stakeFulfilled'
import { handleStakeRequested } from './stakeRequested'
import { handleUnstakeCancelled } from './unstakeCancelled'
import { handleUnstakeConfirmed } from './unstakeConfirmed'
import { handleUnstakeFulfilled } from './unstakeFulfilled'
import { handleUnstakeRequested } from './unstakeRequested'

type EventHandler = (
  ctx: HandlerContext,
  event: ParsedVaultEvent
) => Promise<void>

const HANDLERS: Partial<Record<ParsedVaultEvent['name'], EventHandler>> = {
  StakeRequested: handleStakeRequested,
  StakeFulfilled: handleStakeFulfilled,
  StakeCancelled: handleStakeCancelled,
  UnstakeRequested: handleUnstakeRequested,
  UnstakeConfirmed: handleUnstakeConfirmed,
  UnstakeFulfilled: handleUnstakeFulfilled,
  UnstakeCancelled: handleUnstakeCancelled,
}

export async function dispatchEvent(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  const handler = HANDLERS[event.name]
  if (handler) {
    await handler(ctx, event)
  }
}

export function hasHandler(name: ParsedVaultEvent['name']): boolean {
  return name in HANDLERS
}
