import { updateRequestStatus } from '../../db/data/requests'
import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'

export async function handleUnstakeConfirmed(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  await updateRequestStatus(
    ctx.dbUrl,
    String(event.args.id),
    'UNSTAKE_CONFIRMED',
    {
      flowAmount: String(event.args.flowAmount),
      unlockEpoch: String(event.args.unlockEpoch),
    },
    ctx.tx
  )
}
