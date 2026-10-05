import "LiquidStaking"
import "LiquidStakingConfig"

/// Admin confirms that `amount` of `LiquidStaking.unclassifiedShortfall` is a
/// permanent, unrecoverable loss and clears it from the counter. No backing adjustment is
/// needed: the amount was never added to `totalFlowStaked` while unclassified, so this
/// closes out the claim without ever having inflated the exchange-rate backing.
transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer has no LiquidStakingConfig.Admin")

        LiquidStaking.writeOffShortfall(amount: amount, admin: admin)
    }
}
