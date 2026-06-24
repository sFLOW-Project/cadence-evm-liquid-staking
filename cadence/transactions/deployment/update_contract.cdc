/// Generic in-place contract upgrade for the signer's account.
///
/// Caveats:
///   - `init` does NOT re-run on `update`; storage layout and capability paths must remain
///     compatible. Adding new contract-level vars / fields will not initialise them.
///   - For `LiquidStakingConfig` (whose init mints a COA) and `RelayerRouter` (whose init
///     mints a COA + asserts bridge onboarding) DO NOT use this to migrate to a new init;
///     redeploy the account instead.
///   - Safe for `sFlowToken`, `EVMRoute`, `LiquidStaking` provided storage paths and
///     resource field shapes are unchanged.
///
/// Arguments:
///   - `name`  contract name (e.g. `"LiquidStaking"`)
///   - `code`  contents of the updated contract source file
transaction(name: String, code: String) {
    prepare(signer: auth(UpdateContract) &Account) {
        let _ = signer.contracts.update(name: name, code: code.utf8)
    }
}
