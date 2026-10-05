import "FlowIDTableStaking"

/// test-only: simulate a slash that hits FLOW already reserved in the
/// `unstaked` bucket, so tests can construct a genuine physical shortfall against
/// claims that have already been allocated (see `slashUnstaked` on the mock for
/// rationale).
transaction(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    prepare(signer: &Account) {}
    execute {
        FlowIDTableStaking.slashUnstaked(nodeID: nodeID, delegatorID: delegatorID, amount: amount)
    }
}
