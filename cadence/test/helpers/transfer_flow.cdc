import "FungibleToken"
import "FlowToken"

/// Transfers FLOW from the signer to `recipient`. The recipient must have a
/// `/public/flowTokenReceiver` capability published.
transaction(amount: UFix64, recipient: Address) {
    let sentVault: @{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue) &Account) {
        let vault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FlowToken vault at /storage/flowTokenVault")
        self.sentVault <- vault.withdraw(amount: amount)
    }

    execute {
        let receiver = getAccount(recipient)
            .capabilities
            .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Recipient has no FLOW receiver at /public/flowTokenReceiver")
        receiver.deposit(from: <-self.sentVault)
    }
}
