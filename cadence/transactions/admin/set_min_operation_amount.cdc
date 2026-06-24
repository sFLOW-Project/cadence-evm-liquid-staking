import "LiquidStakingConfig"

/// Set the Cadence-side `minOperationAmount` (the lower bound a single `LiquidStaking.stake`
/// call must exceed) and mirror it to the Solidity LSPVault via `EVMRoute.setMinRequestAmount`.
///
/// `newMin` is expressed in FLOW UFix64 and must be `> 0.0`.
transaction(newMin: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.setMinOperationAmount(newMin: newMin)
    }
}
