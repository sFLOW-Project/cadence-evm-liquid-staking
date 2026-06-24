import "LiquidStakingConfig"

/// Admin path: queues a new `protocolFeePercent` (real config has a 7-day timelock,
/// the stub mirrors that). Activation is gated on `activateProtocolFee`.
transaction(fee: UFix64) {
    let admin: &LiquidStakingConfig.Admin
    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
    }
    execute {
        self.admin.setProtocolFee(newFee: fee)
    }
}
