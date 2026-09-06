import "FungibleToken"
import "FlowToken"
import "LiquidStaking"

/// One-time SFL-01 seed: lock `protocolOwnedSFlowFloor` sFLOW with matching FLOW backing.
/// Run after `register_protocol_delegator.cdc` and before user / relayer stakes.
transaction {
    let payment: @FlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        let flowVault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FlowToken vault; run bootstrap_protocol_account.cdc first")
        self.payment <- flowVault.withdraw(amount: LiquidStaking.protocolOwnedSFlowFloor) as! @FlowToken.Vault
    }

    execute {
        LiquidStaking.seedProtocolOwnedSFlow(from: <-self.payment)
    }
}
