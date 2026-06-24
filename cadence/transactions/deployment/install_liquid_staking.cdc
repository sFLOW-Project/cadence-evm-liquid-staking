/// Installs the `LiquidStaking` contract on the signer account.
///
/// Preconditions (asserted at runtime via `init`):
///   - `LiquidStakingConfig` is already installed on the SAME account (provides
///     `WithdrawPoolStoragePath` used by the init's empty-vault save).
///   - `sFlowToken` is already installed on the SAME account (provides the `Minter`).
///
/// `code` is the contents of `cadence/contracts/LiquidStaking.cdc`. Pass it via
/// `flow transactions send --args-json` as a `String` argument.
transaction(code: String) {
    prepare(signer: auth(AddContract) &Account) {
        let _ = signer.contracts.add(name: "LiquidStaking", code: code.utf8)
    }
}
