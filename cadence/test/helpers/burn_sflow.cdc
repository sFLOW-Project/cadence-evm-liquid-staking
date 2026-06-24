import "FungibleToken"
import "sFlowToken"

/// Burns `amount` sFlow from the signer's vault via the contract's `burnTokens`
/// entry point (which routes through `Burner.burn` and triggers the vault's
/// `burnCallback` to decrement totalSupply).
transaction(amount: UFix64) {
    let toBurn: @sFlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        let vault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &sFlowToken.Vault>(from: sFlowToken.tokenVaultPath)
            ?? panic("Signer has no sFlow vault")
        self.toBurn <- vault.withdraw(amount: amount) as! @sFlowToken.Vault
    }

    execute {
        sFlowToken.burnTokens(from: <-self.toBurn)
    }
}
