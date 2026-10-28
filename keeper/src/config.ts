import { config } from 'dotenv'
import { z } from 'zod'

config()

const flowNetworkSchema = z.enum(['emulator', 'testnet', 'mainnet'])

const rawEnvSchema = z.object({
  EVM_RPC_URL: z.url(),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  NODE_ENV: z.enum(['development', 'production']).default('development'),
  START_BLOCK: z.coerce.number().int().positive(),
  DATABASE_URL: z.string().min(1),
  FLOW_ACCESS_NODE: z.string().url(),
  FLOW_NETWORK: flowNetworkSchema,
  FLOW_PAYER_ADDRESS: z.string().min(1),
  FLOW_PAYER_PRIVATE_KEY: z.string().min(1),
  FLOW_PAYER_KEY_ID: z.coerce.number().int().nonnegative().default(0),
  MAX_BRIDGE_FLOW_FEE: z.string().default('1.0'),
  FINALIZE_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(30_000),
  COMPOUND_POLL_INTERVAL_MS: z.coerce
    .number()
    .int()
    .positive()
    .default(3_600_000),
  FLOW_CONTRACT_RELAYER_ROUTER: z.string().optional(),
  FLOW_CONTRACT_LIQUID_STAKING: z.string().optional(),
  FLOW_CONTRACT_LIQUID_STAKING_CONFIG: z.string().optional(),
  FLOW_CONTRACT_SFLOW_TOKEN: z.string().optional(),
  FLOW_CONTRACT_EVM_ROUTE: z.string().optional(),
  FLOW_CONTRACT_FLOW_EPOCH: z.string().optional(),
})

const envSchema = rawEnvSchema.transform((raw) => ({
  evmRpcUrl: raw.EVM_RPC_URL,
  startBlock: raw.START_BLOCK,
  nodeEnv: raw.NODE_ENV,
  dbUrl: raw.DATABASE_URL,
  logLevel: raw.LOG_LEVEL,
  flowAccessNode: raw.FLOW_ACCESS_NODE,
  flowNetwork: raw.FLOW_NETWORK,
  flowPayerAddress: raw.FLOW_PAYER_ADDRESS,
  flowPayerPrivateKey: raw.FLOW_PAYER_PRIVATE_KEY,
  flowPayerKeyId: raw.FLOW_PAYER_KEY_ID,
  maxBridgeFlowFee: raw.MAX_BRIDGE_FLOW_FEE,
  finalizePollIntervalMs: raw.FINALIZE_POLL_INTERVAL_MS,
  compoundPollIntervalMs: raw.COMPOUND_POLL_INTERVAL_MS,
  flowContractRelayerRouter: raw.FLOW_CONTRACT_RELAYER_ROUTER,
  flowContractLiquidStaking: raw.FLOW_CONTRACT_LIQUID_STAKING,
  flowContractLiquidStakingConfig: raw.FLOW_CONTRACT_LIQUID_STAKING_CONFIG,
  flowContractSFlowToken: raw.FLOW_CONTRACT_SFLOW_TOKEN,
  flowContractEvmRoute: raw.FLOW_CONTRACT_EVM_ROUTE,
  flowContractFlowEpoch: raw.FLOW_CONTRACT_FLOW_EPOCH,
}))

export type Env = z.infer<typeof envSchema>
export type CadenceEnv = Pick<
  Env,
  | 'flowAccessNode'
  | 'flowNetwork'
  | 'flowPayerAddress'
  | 'flowPayerPrivateKey'
  | 'flowPayerKeyId'
  | 'maxBridgeFlowFee'
  | 'flowContractRelayerRouter'
  | 'flowContractLiquidStaking'
  | 'flowContractLiquidStakingConfig'
  | 'flowContractSFlowToken'
  | 'flowContractEvmRoute'
  | 'flowContractFlowEpoch'
>

let cached: Env | null = null

export function getEnv(): Env {
  if (!cached) {
    cached = envSchema.parse(process.env)
  }
  return cached
}
