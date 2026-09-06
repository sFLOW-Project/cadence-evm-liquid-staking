import "FungibleToken"
import "FlowToken"
import "LiquidStaking"

/// Withdraw and destroy every FlowReceipt stored in the signer's collection.
/// Used by tests to clean up shared state before operations that require no
/// outstanding fixed-receipt claims (e.g. `realizeLoss`).
transaction {
    let collection: auth(FungibleToken.Withdraw) &LiquidStaking.FlowReceiptCollection
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.collection = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &LiquidStaking.FlowReceiptCollection>(
                from: LiquidStaking.FlowReceiptCollectionPath
            )
            ?? panic("Signer has no FlowReceiptCollection")
        self.receiver = signer.capabilities
            .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Signer has no FLOW receiver capability")
    }

    execute {
        let infos = self.collection.getFlowReceiptInfos()
        var i = 0
        while i < infos.length {
            let info = infos[i] as! {String: AnyStruct}
            let uuid = info["uuid"]! as! UInt64
            let receipt <- self.collection.withdraw(uuid: uuid)
            let flow <- LiquidStaking.withdraw(receipt: <-receipt)
            self.receiver.deposit(from: <-flow)
            i = i + 1
        }
    }
}
