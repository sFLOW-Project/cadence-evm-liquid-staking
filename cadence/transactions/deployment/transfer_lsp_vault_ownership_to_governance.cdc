import "EVM"
import "EVMRoute"
import "LiquidStakingConfig"

/// **`Ownable`** on **`LSPVault`** starts as **`msg.sender`** = router COA (the deployer). This tx routes **`transferOwnership`**
/// through that same router COA so **`owner`** becomes the **`LiquidStakingConfig`** governance COA ( **`Admin`** resource COA ),
/// matching **`onlyOwner`** checks on **`setProtocolFee`**, **`updateConfig`**, etc., while **`ROUTER_COA`** stays as the immutable router identity.
///
/// Preconditions:
///   - **`LiquidStakingConfig`** installed ( **`governanceCoaEVMAddress()`** available ).
///   - **`lspVaultEvmHex`** is the vault deployed via **`deploy_lsp_vault_evm.cdc`**.
///   - Router COA still present under **`/storage/lspRelayerRouterCOA`** ( **`install_relayer_router.cdc`** not yet run ).
transaction(lspVaultEvmHex: String, gasLimit: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let coa = signer.storage.borrow<auth(EVM.Owner, EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/lspRelayerRouterCOA)
            ?? panic("Router COA missing — run create_router_coa.cdc")

        let vault = EVMRoute.evmAddress(hex: lspVaultEvmHex)
        let newOwner = LiquidStakingConfig.governanceCoaEVMAddress()

        let calldata = EVM.encodeABIWithSignature("transferOwnership(address)", [newOwner])

        let res = coa.call(
            to: vault,
            data: calldata,
            gasLimit: gasLimit,
            value: EVM.Balance(attoflow: 0),
        )

        assert(res.status == EVM.Status.successful, message: res.errorMessage)
    }
}
