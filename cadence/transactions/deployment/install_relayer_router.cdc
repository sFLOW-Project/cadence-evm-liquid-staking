import "EVM"
import "sFlowToken"

/// Installs **`RelayerRouter`** using the router **`CadenceOwnedAccount`** saved by **`create_router_coa.cdc`** at
/// **`/storage/lspRelayerRouterCOA`** ( **must match** the COA that deployed **`LSPVault`** ).
///
/// This transaction **moves** that COA into **`RelayerRouter`**. Before it, run **`fund_router_coa_flow.cdc`** (gas),
/// **`deploy_lsp_vault_evm.cdc`**, **`install_liquid_staking_config.cdc`**, **`transfer_lsp_vault_ownership_to_governance.cdc`**,
/// and **`install_liquid_staking.cdc`**.
///
/// Preconditions (asserted at runtime via **`RelayerRouter`** **`init`** ):
///   - **`sFlowToken`** installed on the SAME account.
///   - **`@sFlowToken.Vault`** onboarded for Flow EVM bridge.
///   - **`FlowEVMBridge`** association for **`sFlowEvmHex`** matches **`vaultIdentifier`**.
///
/// Arguments:
///   - **`code`**............... contents of **`cadence/contracts/RelayerRouter.cdc`** (**String**)
///   - **`lspVaultEvmHex`**..... Solidity **`LSPVault`** address (**must equal** **`LiquidStakingConfig`** **`lspVaultEVMAddress`**)
///   - **`sFlowEvmHex`**....... bridged sFlow ERC-20 on Flow EVM
transaction(
    code: String,
    lspVaultEvmHex: String,
    sFlowEvmHex: String,
) {
    prepare(signer: auth(AddContract, BorrowValue, LoadValue, Capabilities, UnpublishCapability) &Account) {
        let _unusedRouterAddrPub = signer.capabilities.unpublish(/public/lspRouterCOAEvmAddr)

        let coa <- signer.storage.load<@EVM.CadenceOwnedAccount>(from: /storage/lspRelayerRouterCOA)
            ?? panic("Router COA missing — run create_router_coa.cdc before deploy + install")

        let vaultIdentifier = Type<@sFlowToken.Vault>().identifier

        let _ = signer.contracts.add(
            name: "RelayerRouter",
            code: code.utf8,
            <-coa,
            lspVaultEvmHex,
            sFlowEvmHex,
            vaultIdentifier,
        )
    }
}
