import { eq, and } from 'drizzle-orm/sql'
import { getCachedDb } from '../index'
import { contracts } from '../schema'
import { Contract } from '../../models'

export async function getContracts(
  dbUrl: string,
  chainId: number
): Promise<Contract[] | null> {
  const db = getCachedDb(dbUrl)
  return (
    (await db.query.contracts.findMany({
      where: eq(contracts.chain_id, chainId),
    })) ?? null
  )
}

export async function createContract(
  dbUrl: string,
  contract: Contract,
  tx: any
): Promise<void> {
  const db = tx || getCachedDb(dbUrl)
  await db.insert(contracts).values(contract)
}

export async function deleteContract(
  dbUrl: string,
  address: string,
  chainId: number,
  tx: any
): Promise<void> {
  const db = tx || getCachedDb(dbUrl)
  await db
    .delete(contracts)
    .where(and(eq(contracts.address, address), eq(contracts.chain_id, chainId)))
}
