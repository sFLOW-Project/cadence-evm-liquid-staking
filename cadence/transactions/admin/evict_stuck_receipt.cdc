import "LiquidStakingConfig"
import "RelayerRouter"

/// Admin-only recovery for an EVM unstake whose `FlowReceipt` is stuck in
/// `RelayerRouter.evmRequestIdToReceipt`. Must be signed by the protocol account
/// that holds `LiquidStakingConfig.Admin`.
transaction(unstakeRequestId: UInt256) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")
        RelayerRouter.evictStuckReceipt(
            unstakeRequestId: unstakeRequestId,
            admin: admin
        )
    }
}
