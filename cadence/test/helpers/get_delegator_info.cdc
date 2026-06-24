import "FlowIDTableStaking"
import "LiquidStaking"

/// Returns a snapshot of the protocol delegator's bucket balances:
///   `[tokensCommitted, tokensStaked, tokensUnstaking, tokensUnstaked, tokensRewarded]`
access(all)
fun main(): [UFix64] {
    let info = LiquidStaking.getDelegatorInfo()
    return [
        info.tokensCommitted,
        info.tokensStaked,
        info.tokensUnstaking,
        info.tokensUnstaked,
        info.tokensRewarded
    ]
}
