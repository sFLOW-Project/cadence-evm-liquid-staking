import "FlowIDTableStaking"

/// Credit `amount` FLOW from the staking-mock's reward pool into the delegator's
/// `tokensRewarded` bucket so `LiquidStaking.compoundRewards()` sees rewards to
/// compound on the next call.
transaction(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    prepare(signer: &Account) {}
    execute {
        FlowIDTableStaking.accrueRewards(nodeID: nodeID, delegatorID: delegatorID, amount: amount)
    }
}
