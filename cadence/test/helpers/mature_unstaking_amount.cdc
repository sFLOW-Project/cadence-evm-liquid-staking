import "FlowIDTableStaking"

/// Mature `amount` FLOW from the mock delegator's `unstaking` bucket into
/// `unstaked`. Leaves any remainder in `unstaking` so tests can drive a short
/// unstaked bucket for `withdrawStuckReceipt`.
transaction(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    prepare(signer: &Account) {}
    execute {
        FlowIDTableStaking.matureUnstakingAmount(
            nodeID: nodeID,
            delegatorID: delegatorID,
            amount: amount
        )
    }
}
