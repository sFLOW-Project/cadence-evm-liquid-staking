import * as fcl from '@onflow/fcl'

import { CadenceEnv } from '../config'
import { ContractAliases, getNetworkPresets } from './networks'

let configured = false

const OVERRIDE_KEYS: Record<string, keyof CadenceEnv> = {
  RelayerRouter: 'flowContractRelayerRouter',
  LiquidStaking: 'flowContractLiquidStaking',
  LiquidStakingConfig: 'flowContractLiquidStakingConfig',
  sFlowToken: 'flowContractSFlowToken',
  EVMRoute: 'flowContractEvmRoute',
  FlowEpoch: 'flowContractFlowEpoch',
}

export function configureFcl(env: CadenceEnv): void {
  if (configured) return

  fcl.config().put('accessNode.api', env.flowAccessNode)
  fcl.config().put('flow.network', env.flowNetwork)

  const aliases: ContractAliases = getNetworkPresets(env.flowNetwork)

  for (const [name, envKey] of Object.entries(OVERRIDE_KEYS)) {
    const override = env[envKey] as string | undefined
    if (override) {
      aliases[name] = normalizeAddress(override)
    }
  }

  for (const [name, address] of Object.entries(aliases)) {
    // Legacy `import X from 0xX` placeholder syntax.
    fcl.config().put(`0x${name}`, address)
    // Current `import "X"` identifier syntax (used by cadence/transactions/relayer/*.cdc
    // and the keeper's local copies under src/cadence/transactions|scripts).
    fcl.config().put(`system.contracts.${name}`, address)
  }

  configured = true
}

function normalizeAddress(addr: string): string {
  return addr.startsWith('0x') ? addr : `0x${addr}`
}
