import "LiquidStakingConfig"

/// Admin marks a DelegatorSet slot as Draining and clears it as deposit target.
transaction(slotId: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
        admin.markDraining(slotId: slotId)
    }
}
