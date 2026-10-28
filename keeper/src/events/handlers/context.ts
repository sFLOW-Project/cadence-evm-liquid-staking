import { CadenceClient } from '../../cadence/client'
import { Env } from '../../config'

export type HandlerContext = {
  dbUrl: string
  chainId: number
  cadence: CadenceClient
  env: Env
  tx?: any
}
