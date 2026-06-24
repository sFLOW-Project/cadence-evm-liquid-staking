import "LiquidStakingConfig"

/// Returns the canonical hex string (with `0x` prefix) of the Solidity LSPVault that the
/// protocol's `Admin` was bound to at install-time. Use this to verify the Cadence side is
/// pointed at the expected EVM peer before running any relayer operation.
access(all) fun main(): String {
    let hex = LiquidStakingConfig.lspVaultEVMAddress().toString()
    return "0x\(hex)"
}
