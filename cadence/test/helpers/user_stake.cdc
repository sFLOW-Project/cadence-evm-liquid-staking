import "FungibleToken"
import "FlowToken"
import "sFlowToken"
import "LiquidStaking"

/// User stakes `amount` FLOW and stores the minted sFlow in their own vault.
transaction(amount: UFix64) {
    let payment: @FlowToken.Vault
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue, Capabilities) &Account) {
        let flowVault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FlowToken vault")
        self.payment <- flowVault.withdraw(amount: amount) as! @FlowToken.Vault
        self.receiver = signer.capabilities
            .borrow<&{FungibleToken.Receiver}>(sFlowToken.tokenReceiverPath)
            ?? panic("Signer has no sFlow receiver capability")
    }

    execute {
        let sFlow <- LiquidStaking.stake(from: <-self.payment)
        self.receiver.deposit(from: <-sFlow)
    }
}
