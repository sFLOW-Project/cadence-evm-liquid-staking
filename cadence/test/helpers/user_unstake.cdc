import "FungibleToken"
import "sFlowToken"
import "LiquidStaking"

/// User unstakes `amount` sFlow and deposits the returned FlowReceipt into a
/// `FlowReceiptCollection` at `LiquidStaking.FlowReceiptCollectionPath`
/// (created lazily on first call).
transaction(amount: UFix64) {
    let sFlow: @sFlowToken.Vault
    let collectionRef: &LiquidStaking.FlowReceiptCollection

    prepare(signer: auth(BorrowValue, SaveValue, Capabilities) &Account) {
        let vault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &sFlowToken.Vault>(from: sFlowToken.tokenVaultPath)
            ?? panic("Signer has no sFlow vault")
        self.sFlow <- vault.withdraw(amount: amount) as! @sFlowToken.Vault

        if signer.storage.borrow<&LiquidStaking.FlowReceiptCollection>(
            from: LiquidStaking.FlowReceiptCollectionPath
        ) == nil {
            let coll <- LiquidStaking.createEmptyFlowReceiptCollection()
            signer.storage.save(<-coll, to: LiquidStaking.FlowReceiptCollectionPath)
            let cap = signer.capabilities.storage.issue<&{LiquidStaking.FlowReceiptCollectionPublic}>(
                LiquidStaking.FlowReceiptCollectionPath
            )
            signer.capabilities.publish(cap, at: LiquidStaking.FlowReceiptCollectionPublicPath)
        }
        self.collectionRef = signer.storage
            .borrow<&LiquidStaking.FlowReceiptCollection>(from: LiquidStaking.FlowReceiptCollectionPath)
            ?? panic("FlowReceiptCollection not found after init")
    }

    execute {
        let receipt <- LiquidStaking.unstake(from: <-self.sFlow)
        self.collectionRef.deposit(receipt: <-receipt)
    }
}
