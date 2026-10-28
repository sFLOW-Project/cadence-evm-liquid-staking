import { updateRequestStatus } from '../../db/data/requests'
import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'

export async function handleStakeFulfilled(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  await updateRequestStatus(
    ctx.dbUrl,
    String(event.args.id),
    'FULFILLED',
    { sFlowAmount: String(event.args.sFlowAmount) },
    ctx.tx
  )
}
