import "EVM"

/// Deploys **`LSPVault`** bytecode from the router COA saved at **`/storage/lspRelayerRouterCOA`**.
///
/// **`bytecode`** must be the **full creation bytecode** your Solidity toolchain emits for **`LSPVault`**, already
/// concatenated with ABI-encoded constructor arguments **`(address _sFlowAddress, address _routerCOA)`** where:
///   - **`_sFlowAddress`** is the bridged sFlow ERC-20 on Flow EVM (same hex later passed to **`install_relayer_router.cdc`**).
///   - **`_routerCOA`** equals the router COA's EVM address (see **`cadence/scripts/admin/get_router_coa_evm_address.cdc`**).
///
/// Locally (Foundry):
///
/// ```bash
/// ROUTER=$(flow scripts execute cadence/scripts/admin/get_router_coa_evm_address.cdc ... )
/// BYTECODE=$(jq -r '.deployedBytecode.object' evm/out/LSPVault.sol/LSPVault.json)
/// ARGS=$(cast abi-encode "constructor(address,address)" "$SFLOW_HEX" "$ROUTER")
/// INIT=$(cast concat-hex "$BYTECODE" "$ARGS")
/// ```
///
/// Then pass **`INIT`** as a **`[UInt8]`** JSON argument to **`flow transactions send`** (large payloads may require splitting —
/// prefer **`--args-file`** if your CLI supports it).
///
/// **`gasLimit`** — deployment size is large; **`15_000_000`** is a reasonable starting point on devnet if undersized deploys revert.
transaction(bytecode: [UInt8], gasLimit: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let coa = signer.storage.borrow<auth(EVM.Owner, EVM.Deploy) &EVM.CadenceOwnedAccount>(from: /storage/lspRelayerRouterCOA)
            ?? panic("Router COA missing — run create_router_coa.cdc")

        let res = coa.deploy(
            code: bytecode,
            gasLimit: gasLimit,
            value: EVM.Balance(attoflow: 0),
        )

        assert(res.status == EVM.Status.successful, message: res.errorMessage)
        assert(res.deployedContract != nil, message: "deploy produced no contract address")
    }
}
