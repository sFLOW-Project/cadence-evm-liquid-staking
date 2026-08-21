import "LiquidStakingConfig"

/// Admin sets the Active deposit target slot for new stakes.
transaction(slotId: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
        admin.setDepositTarget(slotId: slotId)
    }
}
