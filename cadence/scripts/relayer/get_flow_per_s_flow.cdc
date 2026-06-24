import "LiquidStaking"

/// Live Cadence-side exchange rate (FLOW per 1 sFlow), `1.0` when the supply is zero.
/// The relayer compares this to the value most recently sent to the LSPVault via `syncRate`
/// to detect drift between the two ledgers.
access(all) fun main(): UFix64 {
    return LiquidStaking.flowPerSFlow()
}
