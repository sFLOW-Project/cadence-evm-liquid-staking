import "LiquidStakingConfig"

/// Admin path to pause / unpause `LiquidStaking.stake()`.
/// Signer must own `LiquidStakingConfig.Admin`.
transaction(paused: Bool) {
    let admin: &LiquidStakingConfig.Admin
    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
    }
    execute {
        self.admin.setStakingPaused(paused: paused)
    }
}
