import { desc } from 'drizzle-orm'
import { and, eq, gte, lte } from 'drizzle-orm/sql'
import { BlockParams } from '../../models'

import { getCachedDb } from '..'
import { Env } from '../../config'
import { blocks } from '../schema'

export async function getLatestBlock(
  dbUrl: string,
  chainId: number
): Promise<BlockParams | null> {
  const db = getCachedDb(dbUrl)
  return (
    (await db.query.blocks.findFirst({
      orderBy: desc(blocks.number),
      where: eq(blocks.chain_id, chainId),
    })) ?? null
  )
}

export async function getBlocksInRange(
  dbUrl: string,
  chainId: number,
  start: number,
  end: number
): Promise<BlockParams[] | null> {
  const db = getCachedDb(dbUrl)
  return await db.query.blocks.findMany({
    where: and(
      eq(blocks.chain_id, chainId),
      gte(blocks.number, start),
      lte(blocks.number, end)
    ),
    orderBy: desc(blocks.number),
  })
}

export async function createBlock(dbUrl: string, block: BlockParams, tx: any) {
  const db = tx || getCachedDb(dbUrl)
  await db
    .insert(blocks)
    .values({
      number: block.number,
      chain_id: block.chain_id,
      hash: block.hash,
      timestamp: block.timestamp,
    })
    .onConflictDoNothing()
}

export async function deleteBlock(
  dbUrl: string,
  number: number,
  chainId: number,
  tx: any
) {
  const db = tx || getCachedDb(dbUrl)
  await db
    .delete(blocks)
    .where(and(eq(blocks.number, number), eq(blocks.chain_id, chainId)))
}
