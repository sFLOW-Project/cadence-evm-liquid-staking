import { updateRequestStatus } from '../../db/data/requests'
import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'

export async function handleUnstakeFulfilled(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  await updateRequestStatus(
    ctx.dbUrl,
    String(event.args.id),
    'FULFILLED',
    { amount: String(event.args.amount) },
    ctx.tx
  )
}
