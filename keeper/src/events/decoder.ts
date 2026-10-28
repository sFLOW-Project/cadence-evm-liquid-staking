import { Interface, LogParams } from 'ethers'

import { LSP_VAULT_EVENTS_ABI } from '../abi/lspVault'
import { LogWithTimestamp } from '../models'
import { buildEventId } from './id'
import { ParsedVaultEvent, VaultEventName } from './types'

const iface = new Interface([...LSP_VAULT_EVENTS_ABI])

export function getEventTopicHashes(): string[] {
  return LSP_VAULT_EVENTS_ABI.map((fragment) => {
    const name = fragment.match(/event (\w+)/)?.[1]
    if (!name) throw new Error(`Invalid event fragment: ${fragment}`)
    return iface.getEvent(name)!.topicHash
  })
}

function serializeArgs(
  args: Record<string, unknown>
): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(args)) {
    if (typeof value === 'bigint') {
      out[key] = value.toString()
    } else if (Array.isArray(value)) {
      out[key] = value.map((v) =>
        typeof v === 'bigint' ? v.toString() : v
      )
    } else {
      out[key] = value
    }
  }
  return out
}

export function decodeVaultLog(
  log: LogWithTimestamp
): ParsedVaultEvent | null {
  try {
    const parsed = iface.parseLog(log as LogParams)
    if (!parsed) return null

    const rawArgs: Record<string, unknown> = {}
    for (const input of parsed.fragment.inputs) {
      rawArgs[input.name] = parsed.args[input.name]
    }
    const args = serializeArgs(rawArgs)

    return {
      eventId: buildEventId(log),
      log,
      name: parsed.name as VaultEventName,
      args,
    }
  } catch {
    return null
  }
}
