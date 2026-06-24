import "LiquidStakingConfig"

/// Queue a protocol fee change. Stages the new value and arms the 7-day timelock
/// (`protocolFeeTimelockDuration = 604800`). Must be activated via
/// `activate_protocol_fee.cdc` once `protocolFeeTimelockExpiration` is in the past.
///
/// Re-queueing before activation overwrites the previous queued value and restarts the timer.
///
/// Args:
///   - `newFee`  candidate fee ratio (UFix64), `<= 0.2` (enforced by the Admin precondition)
transaction(newFee: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.setProtocolFee(newFee: newFee)
    }
}
