import "LiquidStakingConfig"

/// Toggle the protocol-wide staking pause. Updates the Cadence flag AND mirrors the change
/// to the Solidity LSPVault via `EVMRoute.setStakingPaused` so the two sides cannot drift.
transaction(paused: Bool) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.setStakingPaused(paused: paused)
    }
}
