import "FungibleToken"
import "FlowToken"
import "LiquidStaking"

/// Stakes `LiquidStaking.protocolOwnedSFlowFloor` FLOW and locks the minted sFLOW
/// in the protocol contract. Run once after a deposit-target delegator is registered.
transaction {
    let payment: @FlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        let flowVault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FlowToken vault")
        self.payment <- flowVault.withdraw(amount: LiquidStaking.protocolOwnedSFlowFloor) as! @FlowToken.Vault
    }

    execute {
        LiquidStaking.seedProtocolOwnedSFlow(from: <-self.payment)
    }
}
