import "LiquidStakingConfig"

/// Set the extra epoch delay added to every NEW and PENDING `FlowReceipt.unlockEpoch` before
/// `LiquidStaking.withdraw` allows redemption. Capped at 2 epochs by the Admin precondition.
///
/// Cadence-only change (the EVM side does not track this delay; it relies on the relayer to
/// honour Cadence's reported `unlockEpoch`).
transaction(newDelay: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.setUnstakeUnlockEpochDelay(newDelay: newDelay)
    }
}
