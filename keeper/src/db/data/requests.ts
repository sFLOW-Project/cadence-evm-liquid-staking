import { and, eq } from 'drizzle-orm/sql'

import { getCachedDb } from '..'
import { requests } from '../schema'

export type RequestType = 'stake' | 'unstake'

export type RequestStatus =
  | 'QUEUED'
  | 'AWAITING_FULFILLMENT'
  | 'UNSTAKE_CONFIRMED'
  | 'FULFILLED'
  | 'CANCELLED'

export type RequestData = {
  user: string
  amount: string
  flowAmount?: string
  unlockEpoch?: string
  sFlowAmount?: string
  refundWei?: string
}

export type RequestRow = {
  id: string
  type: RequestType
  version: number
  chain_id: number
  event_id: string
  requester: string
  status: RequestStatus
  data: RequestData
  created_at: string
  updated_at: string
}

export async function getRequestById(
  dbUrl: string,
  id: string,
  version = 1
): Promise<RequestRow | null> {
  const db = getCachedDb(dbUrl)
  const row = await db.query.requests.findFirst({
    where: and(eq(requests.id, id), eq(requests.version, version)),
  })
  return row ? (row as unknown as RequestRow) : null
}

export async function upsertRequest(
  dbUrl: string,
  row: RequestRow,
  tx?: any
): Promise<void> {
  const db = tx ?? getCachedDb(dbUrl)
  await db
    .insert(requests)
    .values(row)
    .onConflictDoUpdate({
      target: [requests.id, requests.version],
      set: {
        status: row.status,
        data: row.data,
        updated_at: row.updated_at,
      },
    })
}

export async function updateRequestStatus(
  dbUrl: string,
  id: string,
  status: RequestStatus,
  dataPatch?: Partial<RequestData>,
  tx?: any
): Promise<void> {
  const db = tx ?? getCachedDb(dbUrl)
  const existing = await getRequestById(dbUrl, id)
  if (!existing) return

  await db
    .update(requests)
    .set({
      status,
      data: dataPatch ? { ...existing.data, ...dataPatch } : existing.data,
      updated_at: new Date().toISOString(),
    })
    .where(and(eq(requests.id, id), eq(requests.version, 1)))
}

export async function getUnstakesAwaitingFinalize(
  dbUrl: string,
  chainId: number
): Promise<RequestRow[]> {
  const db = getCachedDb(dbUrl)
  const rows = await db.query.requests.findMany({
    where: and(
      eq(requests.chain_id, chainId),
      eq(requests.type, 'unstake'),
      eq(requests.status, 'UNSTAKE_CONFIRMED')
    ),
  })
  return rows as unknown as RequestRow[]
}
