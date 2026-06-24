import "FungibleToken"
import "FlowToken"
import "LiquidStakingConfig"

/// Protocol admin path. The signer must own the `LiquidStakingConfig.Admin` resource
/// (the protocol account). Funds the registration with `amount` FLOW from the signer's
/// own `/storage/flowTokenVault`.
transaction(nodeID: String, amount: UFix64) {
    let admin: &LiquidStakingConfig.Admin
    let funds: @FlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Signer is not the LiquidStakingConfig admin")
        let vault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FlowToken vault at /storage/flowTokenVault")
        self.funds <- vault.withdraw(amount: amount) as! @FlowToken.Vault
    }

    execute {
        self.admin.registerDelegator(nodeID: nodeID, from: <-self.funds)
    }
}
