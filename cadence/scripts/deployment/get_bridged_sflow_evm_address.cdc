import "sFlowToken"
import "FlowEVMBridge"

/// Returns the `0x`-prefixed hex of the bridged sFlow ERC-20 on Flow EVM, derived from the
/// Flow EVM bridge's association for `Type<@sFlowToken.Vault>()`. Requires
/// `onboard_sflow_token_type_for_evm_bridge.cdc` to have run first.
///
/// Used by the deploy pipeline to supply `_sFlowAddress` to the `LSPVault` constructor
/// (`deploy_lsp_vault_evm.cdc`) and `sFlowEvmHex` to `install_relayer_router.cdc`.
access(all) fun main(): String {
    let vaultType = Type<@sFlowToken.Vault>()
    let evmAddr = FlowEVMBridge.getAssociatedEVMAddress(with: vaultType)
        ?? panic("No FlowEVMBridge association for sFlowToken.Vault — run onboard_sflow_token_type_for_evm_bridge.cdc")
    return "0x\(evmAddr.toString())"
}
