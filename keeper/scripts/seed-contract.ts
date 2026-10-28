import { config } from 'dotenv'

import { createContract, deleteContract } from '../src/db/data/contracts'
import { getCachedDb } from '../src/db'

config()

async function main() {
  const dbUrl =
    process.env.DATABASE_URL ?? 'postgresql://keeper:keeper@localhost:5432/keeper'
  const address = process.env.VAULT_ADDRESS
  const chainId = Number(process.env.CHAIN_ID ?? '646')
  const startingBlock = Number(
    process.env.STARTING_BLOCK ?? process.env.START_BLOCK ?? '0'
  )

  if (!address) throw new Error('VAULT_ADDRESS is required')

  const db = getCachedDb(dbUrl)
  await deleteContract(dbUrl, address.toLowerCase(), chainId, db)
  await createContract(dbUrl, {
    address: address.toLowerCase(),
    chain_id: chainId,
    starting_block: startingBlock,
  })

  console.log('Seeded contract', { address, chainId, startingBlock })
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
