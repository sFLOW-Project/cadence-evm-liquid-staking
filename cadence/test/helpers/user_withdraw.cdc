import "FungibleToken"
import "FlowToken"
import "LiquidStaking"

/// User withdraws the FLOW backing a single FlowReceipt identified by `uuid`.
transaction(uuid: UInt64) {
    let receipt: @LiquidStaking.FlowReceipt
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        let coll = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &LiquidStaking.FlowReceiptCollection>(
                from: LiquidStaking.FlowReceiptCollectionPath
            )
            ?? panic("Signer has no FlowReceiptCollection")
        self.receipt <- coll.withdraw(uuid: uuid)
        self.receiver = signer.capabilities
            .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Signer has no FLOW receiver capability")
    }

    execute {
        let flow <- LiquidStaking.withdraw(receipt: <-self.receipt)
        self.receiver.deposit(from: <-flow)
    }
}
