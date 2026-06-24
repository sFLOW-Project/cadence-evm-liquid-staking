import "FungibleToken"
import "FlowToken"
import "EVM"

/// Sends FLOW from the signer's **`/storage/flowTokenVault`** into the router COA's native FLOW balance so it can pay
/// Flow EVM gas for **`deploy`** / **`call`** ( **`deploy_lsp_vault_evm.cdc`**, **`transfer_lsp_vault_ownership_to_governance.cdc`** ).
transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/lspRelayerRouterCOA)
            ?? panic("Router COA missing — run create_router_coa.cdc")

        let vault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("FLOW vault missing — run bootstrap_protocol_account.cdc")

        let payment <- vault.withdraw(amount: amount) as! @FlowToken.Vault
        coa.deposit(from: <-payment)
    }
}
