export type FlowNetwork = 'emulator' | 'testnet' | 'mainnet'

export type ContractAliases = Record<string, string>

const MAINNET: ContractAliases = {
  FungibleToken: '0xf233dcee88fe0abe',
  FlowToken: '0x1654653399040a61',
  EVM: '0xe467b9dd11fa00df',
  FlowEpoch: '0x8624b52f9ddcd04a',
  ScopedFTProviders: '0x1e4aa0b87d10b141',
  FlowEVMBridge: '0x1e4aa0b87d10b141',
  FlowEVMBridgeUtils: '0x1e4aa0b87d10b141',
}

const TESTNET: ContractAliases = {
  FungibleToken: '0x9a0766d93b6608b7',
  FlowToken: '0x7e60df042a9c0868',
  EVM: '0x8c5303eaa26202d6',
  FlowEpoch: '0x9eca2b38b18b5dfe',
  ScopedFTProviders: '0xdfc20aee650fcbdf',
  FlowEVMBridge: '0xdfc20aee650fcbdf',
  FlowEVMBridgeUtils: '0xdfc20aee650fcbdf',
}

const EMULATOR: ContractAliases = {
  FungibleToken: '0xee82856bf20e2aa6',
  FlowToken: '0x0ae53cb6e3f42a79',
  EVM: '0xf8d6e0586b0a20c7',
  FlowEpoch: '0xf8d6e0586b0a20c7',
  ScopedFTProviders: '0xf8d6e0586b0a20c7',
  FlowEVMBridge: '0xf8d6e0586b0a20c7',
  FlowEVMBridgeUtils: '0xf8d6e0586b0a20c7',
}

export function getNetworkPresets(network: FlowNetwork): ContractAliases {
  switch (network) {
    case 'mainnet':
      return { ...MAINNET }
    case 'testnet':
      return { ...TESTNET }
    case 'emulator':
      return { ...EMULATOR }
  }
}
