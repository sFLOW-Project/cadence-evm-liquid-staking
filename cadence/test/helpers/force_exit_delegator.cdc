import "FlowIDTableStaking"

/// Simulate a Flow node full-exit for one mock delegator.
transaction(nodeID: String, delegatorID: UInt32) {
    prepare(signer: &Account) {}
    execute {
        FlowIDTableStaking.forceExitDelegator(nodeID: nodeID, delegatorID: delegatorID)
    }
}
