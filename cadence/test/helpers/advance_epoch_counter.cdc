import "FlowEpoch"

/// Advance the mock epoch counter by `n` without maturing unstaking buckets.
/// Pair with `mature_unstaking_amount.cdc` when a test needs unlock-epoch to
/// pass while leaving some FLOW in `tokensUnstaking`.
transaction(n: UInt64) {
    prepare(signer: &Account) {}
    execute {
        FlowEpoch.advanceEpoch(by: n)
    }
}
