import { join } from 'path'

import * as dotenv from 'dotenv'
import { migrate } from 'drizzle-orm/postgres-js/migrator'

import { createDb } from './index'

dotenv.config()

async function main() {
  if (!process.env.DATABASE_URL) {
    throw new Error('DATABASE_URL environment variable is required')
  }

  const db = createDb(process.env.DATABASE_URL)

  console.log('Running migrations...')

  await migrate(db, { migrationsFolder: join(__dirname, 'migrations') })

  console.log('Migrations completed successfully')

  process.exit(0)
}

main().catch((error) => {
  console.error('Migration failed:', error)
  process.exit(1)
})
