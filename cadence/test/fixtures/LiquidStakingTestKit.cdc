import "LiquidStaking"
import "FlowToken"

/// Test-only contract co-deployed with `LiquidStaking` so transactions can
/// reach `LiquidStaking.compoundRewards()`, which is `access(account)` and
/// therefore only callable from another contract on the same account.
access(all) contract LiquidStakingTestKit {
    access(all) fun compoundRewards() {
        LiquidStaking.compoundRewards()
    }

    access(all) fun withdrawStuckReceipt(receipt: @LiquidStaking.FlowReceipt): @FlowToken.Vault {
        return <- LiquidStaking.withdrawStuckReceipt(receipt: <-receipt)
    }
}
