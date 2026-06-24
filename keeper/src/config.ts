import { config } from 'dotenv'
import { z } from 'zod'

config()

const rawEnvSchema = z.object({
  EVM_RPC_URL: z.url(),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  NODE_ENV: z.enum(['development', 'production']).default('development'),
  START_BLOCK: z.coerce.number().int().positive(),
  DATABASE_URL: z.string().min(1),
})

const envSchema = rawEnvSchema.transform((raw) => ({
  evmRpcUrl: raw.EVM_RPC_URL,
  startBlock: raw.START_BLOCK,
  nodeEnv: raw.NODE_ENV,
  dbUrl: raw.DATABASE_URL,
  logLevel: raw.LOG_LEVEL,
}))

export type Env = z.infer<typeof envSchema>

let cached: Env | null = null

export function getEnv(): Env {
  if (!cached) {
    cached = envSchema.parse(process.env)
  }
  return cached
}
