import "LiquidStakingConfig"

transaction(receiver: Address) {
    let admin: &LiquidStakingConfig.Admin
    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
    }
    execute {
        self.admin.setProtocolFeeReceiver(newReceiver: receiver)
    }
}
