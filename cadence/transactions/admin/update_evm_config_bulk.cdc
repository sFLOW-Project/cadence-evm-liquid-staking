import "LiquidStakingConfig"

/// Batch convenience: apply min / pause / slippage via `Admin.updateConfig`, and
/// (optionally) queue a protocol fee, in a single atomic transaction.
///
/// `updateConfig` writes Cadence min/pause and one EVM `LSPVault.updateConfig`
/// call (min, pause, current Cadence fee, slippage). Fee *changes* still go
/// through the timelock (`setProtocolFee`); they are not applied here.
///
/// Args:
///   - `newMinOperationAmount`  pass the current value to leave unchanged
///   - `paused`                 pass the current value to leave unchanged
///   - `slippageTolerance`      EVM vault max slippage (`<= 0.01` = 1%)
///   - `queueNewFee`            `nil` to skip; otherwise `<= 0.2`. Activation is NOT
///                              performed (timelock still applies).
transaction(
    newMinOperationAmount: UFix64,
    paused: Bool,
    slippageTolerance: UFix64,
    queueNewFee: UFix64?,
) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")

        admin.updateConfig(
            minOperationAmount: newMinOperationAmount,
            paused: paused,
            slippageTolerance: slippageTolerance
        )
        if let fee = queueNewFee {
            admin.setProtocolFee(newFee: fee)
        }
    }
}
