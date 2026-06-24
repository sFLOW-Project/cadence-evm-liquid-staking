/// Test-only mock for Flow's `FlowEpoch` system contract.
///
/// Exposes the minimum surface that `LiquidStaking.cdc` reads
/// (`currentEpochCounter`) plus a public `advanceEpoch(by:)` helper so
/// `flow test` can deterministically flip epochs without driving the real
/// FlowEpoch heartbeat machinery.
access(all) contract FlowEpoch {

    access(all) var currentEpochCounter: UInt64

    access(all) event EpochAdvanced(from: UInt64, to: UInt64)

    /// Advance the mock epoch counter by `amount`. No-op when `amount == 0`.
    access(all) fun advanceEpoch(by amount: UInt64) {
        let from = self.currentEpochCounter
        self.currentEpochCounter = from + amount
        emit EpochAdvanced(from: from, to: self.currentEpochCounter)
    }

    /// Reset the counter (occasionally useful for `beforeEach` patterns).
    access(all) fun resetEpoch(to value: UInt64) {
        self.currentEpochCounter = value
    }

    init() {
        self.currentEpochCounter = 0
    }
}
