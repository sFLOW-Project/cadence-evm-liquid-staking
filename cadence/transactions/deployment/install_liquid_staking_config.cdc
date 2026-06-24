import "EVM"
import "EVMRoute"

/// Installs `LiquidStakingConfig` on the signer account, minting the contract's governance COA
/// in-transaction so it can be passed as the resource init argument.
///
/// The caller must supply the source code of `LiquidStakingConfig.cdc` as `code` (UTF-8 text);
/// using `flow transactions send`, this is typically wired via `--args-json` with the file
/// contents read into a String argument.
///
/// Arguments:
///   - `code` ............... contents of `cadence/contracts/LiquidStakingConfig.cdc` (String)
///   - `protocolFeePercent` .. initial fee ratio (UFix64), `<= 0.2`
///   - `protocolFeeReceiver`. Cadence Address that receives the FLOW protocol fee
///   - `minOperationAmount`.. minimum FLOW per stake/unstake on Cadence (`> 0.0`)
///   - `unstakeUnlockEpochDelay` .. extra epochs added to receipt unlock (`<= 2`)
///   - `lspVaultEvmHex` ..... hex address (with `0x`-prefix tolerated) of the Solidity LSPVault
///                             whose owner is the governance COA created here
///
/// Re-running this against an account that already has `LiquidStakingConfig` will fail; use
/// `update_contract.cdc` instead for upgrades (note: contract init does not re-run on update,
/// so a brand-new COA cannot be installed without redeploying the account).
transaction(
    code: String,
    protocolFeePercent: UFix64,
    protocolFeeReceiver: Address,
    minOperationAmount: UFix64,
    unstakeUnlockEpochDelay: UInt64,
    lspVaultEvmHex: String,
) {
    prepare(signer: auth(AddContract) &Account) {
        let coa <- EVM.createCadenceOwnedAccount()
        let vault = EVMRoute.evmAddress(hex: lspVaultEvmHex)

        let _ = signer.contracts.add(
            name: "LiquidStakingConfig",
            code: code.utf8,
            protocolFeePercent,
            protocolFeeReceiver,
            minOperationAmount,
            unstakeUnlockEpochDelay,
            <-coa,
            vault,
        )
    }
}
