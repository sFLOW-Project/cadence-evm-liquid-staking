import "FlowIDTableStaking"
import "LiquidStaking"

/// Returns the protocol's `FlowIDTableStaking.DelegatorInfo` for the single account-bound
/// delegator. Useful for confirming `registerDelegator` succeeded and for observing per-epoch
/// bucket movements (committed -> staked -> unstaking -> unstaked -> rewarded).
access(all) fun main(): FlowIDTableStaking.DelegatorInfo {
    return LiquidStaking.getDelegatorInfo()
}
