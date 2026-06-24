import "FungibleToken"
import "FlowToken"

/// Idempotently sets up a FLOW vault + public capabilities on the signer's account
/// so it can receive FLOW (used by user / treasury accounts in `flow test`).
transaction {
    prepare(signer: auth(SaveValue, Capabilities, BorrowValue) &Account) {
        if signer.storage.borrow<&FlowToken.Vault>(from: /storage/flowTokenVault) == nil {
            let vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            signer.storage.save(<-vault, to: /storage/flowTokenVault)
        }
        if signer.capabilities.get<&FlowToken.Vault>(/public/flowTokenReceiver) == nil {
            let cap = signer.capabilities.storage.issue<&FlowToken.Vault>(/storage/flowTokenVault)
            signer.capabilities.publish(cap, at: /public/flowTokenReceiver)
        }
        if signer.capabilities.get<&FlowToken.Vault>(/public/flowTokenBalance) == nil {
            let cap = signer.capabilities.storage.issue<&FlowToken.Vault>(/storage/flowTokenVault)
            signer.capabilities.publish(cap, at: /public/flowTokenBalance)
        }
    }
}
