import "LiquidStakingConfig"

/// Returns the hex (with `0x` prefix) of the COA the `Admin` resource was minted with.
/// This address is the `Ownable.owner` of the Solidity LSPVault on the EVM side and is the
/// only EVM identity that can execute owner-restricted vault functions (e.g. `setProtocolFee`).
access(all) fun main(): String {
    let hex = LiquidStakingConfig.governanceCoaEVMAddress().toString()
    return "0x\(hex)"
}
