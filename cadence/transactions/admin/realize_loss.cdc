import "LiquidStaking"
import "LiquidStakingConfig"
import "RelayerRouter"

transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer has no LiquidStakingConfig.Admin")

        LiquidStaking.realizeLoss(amount: amount, admin: admin)

        if LiquidStaking.totalFlowStaked > 0.0 {
            RelayerRouter.syncBacking(admin: admin)
        }
    }
}
