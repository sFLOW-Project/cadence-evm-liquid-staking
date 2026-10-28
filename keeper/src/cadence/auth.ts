import * as fcl from '@onflow/fcl'
import { ec as EC } from 'elliptic'
import { createHash } from 'crypto'

import { CadenceEnv } from '../config'

const ec = new EC('p256')
const ACCOUNT_KEY_ATTEMPTS = 5
const ACCOUNT_KEY_DELAY_MS = 2_000

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function getSequenceNumber(env: CadenceEnv): Promise<number> {
  const address = fcl.sansPrefix(env.flowPayerAddress)
  const url = `${env.flowAccessNode.replace(/\/$/, '')}/v1/accounts/${address}?block_height=final&expand=keys`
  let lastError: unknown

  for (let attempt = 1; attempt <= ACCOUNT_KEY_ATTEMPTS; attempt++) {
    try {
      const response = await fetch(url)
      if (!response.ok) {
        throw new Error(`Flow account key fetch failed: ${response.status} ${response.statusText}`)
      }

      const account = (await response.json()) as {
        keys?: Array<{ index: string; sequence_number: string }>
      }
      const key = account.keys?.find((item) => Number(item.index) === env.flowPayerKeyId)
      if (!key) {
        throw new Error(`Flow account key ${env.flowPayerKeyId} not found`)
      }
      return Number(key.sequence_number)
    } catch (error) {
      lastError = error
      if (attempt < ACCOUNT_KEY_ATTEMPTS) {
        await sleep(ACCOUNT_KEY_DELAY_MS * attempt)
      }
    }
  }

  throw lastError
}

function toCompactHex(sig: ReturnType<EC.KeyPair['sign']>): string {
  const r = sig.r.toString(16).padStart(64, '0')
  const s = sig.s.toString(16).padStart(64, '0')
  return r + s
}

function sha3_256Hex(hexMessage: string): string {
  return createHash('sha3-256')
    .update(Buffer.from(hexMessage, 'hex'))
    .digest('hex')
}

export function createPayerAuthz(env: CadenceEnv) {
  const privateKey = env.flowPayerPrivateKey.replace(/^0x/, '')
  const key = ec.keyFromPrivate(privateKey)
  const address = fcl.sansPrefix(env.flowPayerAddress)
  const keyId = env.flowPayerKeyId

  return async (account: any = {}) => {
    const sequenceNum =
      account.sequenceNum != null ? account.sequenceNum : await getSequenceNumber(env)

    return {
      ...account,
      tempId: `${address}-${keyId}`,
      addr: fcl.withPrefix(account.addr ?? address),
      keyId,
      sequenceNum,
      role: {
        proposer: true,
        payer: true,
        authorizer: true,
      },
      signingFunction: (signable: { message: string }) => ({
        addr: fcl.withPrefix(account.addr ?? address),
        keyId,
        signature: toCompactHex(key.sign(sha3_256Hex(signable.message))),
      }),
    }
  }
}
