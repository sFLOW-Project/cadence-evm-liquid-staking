import "LiquidStakingConfig"

/// Promote the queued protocol fee to the live `protocolFeePercent` and mirror it to the
/// Solidity LSPVault via `EVMRoute.setProtocolFee`. Reverts if no fee is queued or if the
/// 7-day timelock has not yet expired.
transaction {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.activateProtocolFee()
    }
}
