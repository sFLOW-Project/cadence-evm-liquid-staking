import "EVM"

/// Reads the Flow EVM address (**`0x`-prefixed hex**) of the router **`CadenceOwnedAccount`** stored at the protocol account,
/// exposed via **`/public/lspRouterCOAEvmAddr`** (**published by **`create_router_coa.cdc`** ).
///
/// Use this address when ABI-encoding **`LSPVault`** **`constructor(address _sFlowAddress, address _routerCOA)`**.
access(all) fun main(protocol: Address): String {
    let ref = getAccount(protocol).capabilities.borrow<&{EVM.Addressable}>(/public/lspRouterCOAEvmAddr)
        ?? panic("missing /public/lspRouterCOAEvmAddr capability — run create_router_coa.cdc")
    let hex = ref.address().toString()
    return "0x\(hex)"
}
