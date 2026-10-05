import "LiquidStaking"
import "LiquidStakingConfig"
import "RelayerRouter"

/// Admin confirms that `amount` of `LiquidStaking.unclassifiedShortfall` is still
/// recoverable (e.g. FLOW that was merely delayed in the delegator bucket, not permanently
/// lost) and restores it to `totalFlowStaked`. Bounded on-chain so this can never push
/// recorded backing above verified actual backing.
transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer has no LiquidStakingConfig.Admin")

        LiquidStaking.reconcileRecoveredShortfall(amount: amount, admin: admin)

        if LiquidStaking.totalFlowStaked > 0.0 {
            RelayerRouter.syncBacking(admin: admin)
        }
    }
}
