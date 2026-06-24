import "LiquidStakingConfig"

/// Update the Cadence address that receives the FLOW protocol fee on every
/// `LiquidStaking.compoundRewards()` call. `newReceiver` MUST publish a
/// `&{FungibleToken.Receiver}` capability at `LiquidStakingConfig.ProtocolFeeReceiverPublicPath`
/// (= `/public/flowTokenReceiver`); the next compound call would otherwise revert.
///
/// Cadence-only change (no EVM mirror).
transaction(newReceiver: Address) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.setProtocolFeeReceiver(newReceiver: newReceiver)
    }
}
