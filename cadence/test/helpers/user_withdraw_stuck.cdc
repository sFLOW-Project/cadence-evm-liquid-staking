import "FungibleToken"
import "LiquidStaking"
import "LiquidStakingTestKit"

/// Withdraws a receipt via the admin recovery path (`withdrawStuckReceipt`), which
/// ignores retroactive `unstakeUnlockEpochDelay` and pulls available unstaked FLOW.
transaction(uuid: UInt64) {
    prepare(signer: auth(BorrowValue, Storage) &Account) {
        let collection = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &LiquidStaking.FlowReceiptCollection>(
                from: LiquidStaking.FlowReceiptCollectionPath
            ) ?? panic("Signer has no FlowReceiptCollection")

        let receipt <- collection.withdraw(uuid: uuid)
        let flowVault <- LiquidStakingTestKit.withdrawStuckReceipt(receipt: <-receipt)

        let receiver = signer.storage.borrow<&{FungibleToken.Receiver}>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FLOW vault")
        receiver.deposit(from: <-flowVault)
    }
}
