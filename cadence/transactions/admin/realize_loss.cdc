import "LiquidStaking"
import "LiquidStakingConfig"

/// Governance-only: permanently reduce `LiquidStaking.totalFlowStaked` after a
/// confirmed, unrecoverable slashing loss. This prevents phantom backing by making
/// the loss visible in the exchange rate.
transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer has no LiquidStakingConfig.Admin")

        LiquidStaking.realizeLoss(amount: amount, admin: admin)
    }
}
