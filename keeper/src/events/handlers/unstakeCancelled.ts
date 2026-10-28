import { updateRequestStatus } from '../../db/data/requests'
import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'

export async function handleUnstakeCancelled(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  await updateRequestStatus(
    ctx.dbUrl,
    String(event.args.id),
    'CANCELLED',
    {
      amount: String(event.args.amount),
    },
    ctx.tx
  )
}
