import "RelayerRouter"

/// Trigger a single Cadence-side reward compound and push the new `flowPerSFlow` rate to
/// the Solidity LSPVault via `EVMRoute.syncRate`. Safe to invoke any time the staking period
/// is open; if there are no rewards to harvest, `LiquidStaking.compoundRewards()` returns
/// early but the rate sync still runs.
///
/// No fee provider is needed (no bridge crossing happens).
transaction {
    prepare(_signer: &Account) {}
    execute {
        RelayerRouter.compoundAndSyncRate()
    }
}
