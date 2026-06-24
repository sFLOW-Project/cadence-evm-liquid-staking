import "EVM"

/// Creates the relayer **`CadenceOwnedAccount`** that will:
///   1. Deploy **`LSPVault`** on Flow EVM (`deploy_lsp_vault_evm.cdc`) — **`msg.sender`** matches **`ROUTER_COA`**.
///   2. Later be installed into **`RelayerRouter`** (`install_relayer_router.cdc`).
///
/// Stored at **`/storage/lspRelayerRouterCOA`**. A public **`&{EVM.Addressable}`** capability is published at
/// **`/public/lspRouterCOAEvmAddr`** so **`cadence/scripts/admin/get_router_coa_evm_address.cdc`** can read the EVM hex
/// when ABI-encoding the Solidity constructor `(address _sFlowAddress, address _routerCOA)`.
///
/// Run exactly once before **`deploy_lsp_vault_evm.cdc`**.
transaction {
    prepare(signer: auth(SaveValue, Capabilities, BorrowValue) &Account) {
        assert(
            signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/lspRelayerRouterCOA) == nil,
            message: "Router COA already exists at /storage/lspRelayerRouterCOA"
        )

        let coa <- EVM.createCadenceOwnedAccount()
        signer.storage.save(<-coa, to: /storage/lspRelayerRouterCOA)

        let addrCap = signer.capabilities.storage.issue<&{EVM.Addressable}>(/storage/lspRelayerRouterCOA)
        signer.capabilities.publish(addrCap, at: /public/lspRouterCOAEvmAddr)
    }
}
