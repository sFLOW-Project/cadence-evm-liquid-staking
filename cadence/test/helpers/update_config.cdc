import "LiquidStakingConfig"

transaction(minOperationAmount: UFix64, paused: Bool, slippageTolerance: UFix64) {
    let admin: &LiquidStakingConfig.Admin
    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
    }
    execute {
        self.admin.updateConfig(
            minOperationAmount: minOperationAmount,
            paused: paused,
            slippageTolerance: slippageTolerance
        )
    }
}
