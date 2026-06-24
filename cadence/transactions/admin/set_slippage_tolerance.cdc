import "LiquidStakingConfig"

/// EVM-only: update the Solidity LSPVault's slippage tolerance via
/// `EVMRoute.setSlippageTolerance`. The Cadence config is not affected.
///
/// `slippageTolerance` is supplied in UFix64 and converted to the wei-style UInt256 scale
/// inside the `Admin` resource (`EVMRoute.tokenUFix64ToScaledUInt256`).
transaction(slippageTolerance: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        admin.setSlippageTolerance(slippageTolerance: slippageTolerance)
    }
}
