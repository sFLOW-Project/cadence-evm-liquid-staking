import "LiquidStaking"

/// Canonical Cadence exchange rate (`flowPerSFlowScaled`), same 1e18 convention as
/// `LSPVault.syncRate`. Compare this to the vault's stored rate for ledger drift.
access(all) fun main(): UInt256 {
    return LiquidStaking.flowPerSFlowScaled()
}
