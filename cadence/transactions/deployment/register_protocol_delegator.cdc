import "FungibleToken"
import "FlowToken"
import "LiquidStakingConfig"

/// One-shot post-install transaction: registers the protocol's `NodeDelegator` on the staking
/// table by routing `commitAmount` FLOW from the signer's `/storage/flowTokenVault` through
/// `LiquidStakingConfig.Admin.registerDelegator`.
///
/// The resulting `NodeDelegator` is stored at `LiquidStakingConfig.DelegatorStoragePath` and is
/// the single account-bound delegator that `LiquidStaking.stake / unstake / compoundRewards`
/// will borrow.
///
/// Must be called exactly once per deployment. Re-running will panic if a delegator already
/// occupies the storage path.
///
/// Arguments:
///   - `nodeID`        Flow node ID this protocol delegates to
///   - `commitAmount`  initial FLOW committed to bootstrap the delegator (`> 0.0`)
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
