import "FungibleToken"
import "FlowToken"
import "LiquidStakingConfig"

/// One-shot post-install transaction: registers the protocol's `NodeDelegator` on the staking
/// table by routing `commitAmount` FLOW from the signer's `/storage/flowTokenVault` through
/// `LiquidStakingConfig.Admin.registerDelegator`.
///
/// Arguments:
///   - `nodeID`        Flow node ID this protocol delegates to
///   - `commitAmount`  initial FLOW committed to bootstrap the delegator (`> 0.0`)
///
/// Inserts a slot into `DelegatorSet` at `DelegatorStoragePath` (creates the set
/// on first call). Safe to call again to add another node/slot.
transaction(nodeID: String, commitAmount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage
            .borrow<&LiquidStakingConfig.Admin>(from: LiquidStakingConfig.AdminStoragePath)
            ?? panic("Admin resource not found at LiquidStakingConfig.AdminStoragePath")

        let vault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FLOW vault; run bootstrap_protocol_account.cdc first")

        let payment <- vault.withdraw(amount: commitAmount) as! @FlowToken.Vault
        admin.registerDelegator(nodeID: nodeID, from: <-payment)
    }
}
