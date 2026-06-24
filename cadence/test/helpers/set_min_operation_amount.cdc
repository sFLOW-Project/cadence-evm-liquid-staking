import "LiquidStakingConfig"

transaction(amount: UFix64) {
    let admin: &LiquidStakingConfig.Admin
    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
    }
    execute {
        self.admin.setMinOperationAmount(newMin: amount)
    }
}
