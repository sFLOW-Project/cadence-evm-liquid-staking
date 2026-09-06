import "FlowIDTableStaking"

/// Test-only: simulate a slashing event that permanently removes FLOW from a delegator.
transaction(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    prepare(signer: &Account) {}
    execute {
        FlowIDTableStaking.slash(nodeID: nodeID, delegatorID: delegatorID, amount: amount)
    }
}
