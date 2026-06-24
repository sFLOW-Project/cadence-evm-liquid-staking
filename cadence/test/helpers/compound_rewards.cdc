import "LiquidStakingTestKit"

/// Calls into `LiquidStaking.compoundRewards()` via the test-kit shim
/// (the real entry point is `access(account)` and unreachable from a transaction).
transaction {
    prepare(signer: &Account) {}
    execute {
        LiquidStakingTestKit.compoundRewards()
    }
}
