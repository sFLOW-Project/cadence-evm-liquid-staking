import "LiquidStakingConfig"

/// Batch convenience: apply `setMinOperationAmount`, `setStakingPaused`, and (optionally) a
/// fee queue in a single atomic transaction. Each setter mirrors to the Solidity LSPVault.
///
/// Note: this does NOT call `EVMRoute.updateConfig` directly because the `Admin` COA is
/// `access(self)` and inaccessible from a transaction; firing the three individual admin
/// methods has the same end-state and shares the same all-or-nothing semantics inside one
/// Cadence transaction (any sub-call revert rolls the whole txn back).
///
/// Args:
///   - `newMinOperationAmount`  pass the current value to leave unchanged
///   - `paused`                 pass the current value to leave unchanged
///   - `queueNewFee`            `nil` to skip; otherwise `<= 0.2`. Activation is NOT
///                              performed (timelock still applies).
transaction(
    newMinOperationAmount: UFix64,
    paused: Bool,
    queueNewFee: UFix64?,
) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")

        admin.setMinOperationAmount(newMin: newMinOperationAmount)
        admin.setStakingPaused(paused: paused)
        if let fee = queueNewFee {
            admin.setProtocolFee(newFee: fee)
        }
    }
}
