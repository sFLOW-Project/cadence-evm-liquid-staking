import "FlowIDTableStaking"
import "LiquidStaking"

/// Snapshot of the protocol delegator's per-bucket balances at the current epoch boundary.
/// Used by the relayer as a balance gauge when deciding whether `compound_and_sync_rate` or
/// epoch-flip handling should run next.
access(all) fun main(): FlowIDTableStaking.DelegatorInfo {
    return LiquidStaking.getDelegatorInfo()
}
