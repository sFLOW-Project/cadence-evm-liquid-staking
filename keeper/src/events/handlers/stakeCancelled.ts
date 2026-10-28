import { updateRequestStatus } from '../../db/data/requests'
import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'

export async function handleStakeCancelled(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  await updateRequestStatus(
    ctx.dbUrl,
    String(event.args.id),
    'CANCELLED',
    {
      refundWei: String(event.args.refundWei),
    },
    ctx.tx
  )
}
