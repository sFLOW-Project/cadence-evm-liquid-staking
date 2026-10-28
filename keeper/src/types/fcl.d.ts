declare module '@onflow/fcl' {
  type FclType = { Array: (inner: FclType) => FclType; UInt256: FclType; UFix64: FclType }

  export const config: () => {
    put: (key: string, value: unknown) => unknown
  }
  export const sansPrefix: (addr: string) => string
  export const withPrefix: (addr: string) => string
  export function getAccount(addr: string): unknown
  export const send: (args: unknown[]) => Promise<unknown>
  export const decode: (v: unknown) => any
  export const mutate: (opts: unknown) => Promise<string>
  export const txId: (v: unknown) => string
  export const tx: (id: string) => {
    onceSealed: () => Promise<{ status: number; errorMessage?: string }>
    snapshot: () => Promise<{ status: number; errorMessage?: string; statusCode?: number }>
  }
  export const query: (opts: unknown) => Promise<unknown>
  export const arg: (value: unknown, type: FclType) => unknown
  export const t: FclType
}
