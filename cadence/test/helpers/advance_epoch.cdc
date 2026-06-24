import "FlowEpoch"
import "FlowIDTableStaking"

/// Advance the mock epoch counter by `n` and mature any pending `unstaking` buckets
/// so the next `LiquidStaking.withdraw` call can pull FLOW out for receipts whose
/// `unlockEpoch` has been crossed.
transaction(n: UInt64) {
    prepare(signer: &Account) {}
    execute {
        FlowEpoch.advanceEpoch(by: n)
        FlowIDTableStaking.matureAllUnstaking()
    }
}
