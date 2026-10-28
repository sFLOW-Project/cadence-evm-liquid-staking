import { existsSync } from 'fs'
import { join, resolve } from 'path'

import * as dotenv from 'dotenv'
import { migrate } from 'drizzle-orm/postgres-js/migrator'

import { createDb } from './index'

dotenv.config()

async function main() {
  const dbUrl =
    process.env.DATABASE_URL ?? 'postgresql://keeper:keeper@localhost:5432/keeper'
  const db = createDb(dbUrl)

  console.log('Running migrations...')

  const distMigrations = join(__dirname, 'migrations')
  const sourceMigrations = resolve(__dirname, '../../src/db/migrations')
  const migrationsFolder = existsSync(join(distMigrations, 'meta', '_journal.json'))
    ? distMigrations
    : sourceMigrations

  await migrate(db, { migrationsFolder })

  console.log('Migrations completed successfully')

  process.exit(0)
}

main().catch((error) => {
  console.error('Migration failed:', error)
  process.exit(1)
})
