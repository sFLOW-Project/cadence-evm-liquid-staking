import "FungibleToken"
import "sFlowToken"

/// Idempotently sets up a sFlow vault + interface-typed public capabilities
/// (`&{FungibleToken.Receiver}` and `&{FungibleToken.Balance}`) on the signer.
transaction {
    prepare(signer: auth(SaveValue, Capabilities, BorrowValue, UnpublishCapability) &Account) {
        if signer.storage.borrow<&sFlowToken.Vault>(from: sFlowToken.tokenVaultPath) == nil {
            let vault <- sFlowToken.createEmptyVault(vaultType: Type<@sFlowToken.Vault>())
            signer.storage.save(<-vault, to: sFlowToken.tokenVaultPath)
        }
        signer.capabilities.unpublish(sFlowToken.tokenReceiverPath)
        let recvCap = signer.capabilities.storage.issue<&{FungibleToken.Receiver}>(sFlowToken.tokenVaultPath)
        signer.capabilities.publish(recvCap, at: sFlowToken.tokenReceiverPath)

        signer.capabilities.unpublish(sFlowToken.tokenBalancePath)
        let balCap = signer.capabilities.storage.issue<&{FungibleToken.Balance}>(sFlowToken.tokenVaultPath)
        signer.capabilities.publish(balCap, at: sFlowToken.tokenBalancePath)
    }
}
