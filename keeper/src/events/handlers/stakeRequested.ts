import { upsertRequest } from '../../db/data/requests'
import { ParsedVaultEvent } from '../types'
import { HandlerContext } from './context'

export async function handleStakeRequested(
  ctx: HandlerContext,
  event: ParsedVaultEvent
): Promise<void> {
  const requestId = String(event.args.id)
  const now = new Date().toISOString()

  await upsertRequest(
    ctx.dbUrl,
    {
      id: requestId,
      type: 'stake',
      version: 1,
      chain_id: ctx.chainId,
      event_id: event.eventId,
      requester: String(event.args.user),
      status: 'QUEUED',
      data: {
        user: String(event.args.user),
        amount: String(event.args.amount),
      },
      created_at: now,
      updated_at: now,
    },
    ctx.tx
  )

  await ctx.cadence.handleStakes([requestId])
}
