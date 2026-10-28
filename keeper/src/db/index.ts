import { drizzle } from 'drizzle-orm/postgres-js'
import postgres from 'postgres'

import * as relations from './relations'
import * as schema from './schema'

// Export schema and relations for consumers
export * from './schema'
export * from './relations'

// Create a database connection function
export function createDb(
  connectionString: string,
  options: postgres.Options<{}> = {}
) {
  // Create the postgres client
  const queryClient = postgres(connectionString, {
    idle_timeout: (options as any).idle_timeout ?? 5,
    connect_timeout: (options as any).connect_timeout ?? 5,
    ...options,
  })

  // Create the drizzle instance
  const db = drizzle(queryClient, {
    schema: { ...schema, ...relations },
  })

  // Add the query client to the db instance for cleanup
  return db
}

export function getDb(
  connectionString: string,
  options: postgres.Options<{}> = {}
) {
  // Create a fresh instance per request - caching causes I/O context errors in Cloudflare Workers
  return createDb(connectionString, options)
}

// Cache for database connections (for AWS/Kubernetes environments)
const dbCache = new Map<string, ReturnType<typeof createDb>>()

export function getCachedDb(
  connectionString: string,
  options: postgres.Options<{}> = {}
) {
  const key = connectionString
  const existing = dbCache.get(key)
  if (existing) return existing

  // Set max connections for AWS/Kubernetes environments
  const instance = createDb(connectionString, {
    max: (options as any).max ?? 5,
    ...options,
  })
  dbCache.set(key, instance)
  return instance
}
