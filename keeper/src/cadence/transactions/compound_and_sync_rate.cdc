import "RelayerRouter"

/// Per-epoch housekeeping: compounds Flow staking rewards into `LiquidStaking.totalFlowStaked`
/// (no new sFlow minted) and pushes the refreshed `totalFlowStaked` / `sFlowToken.totalSupply`
/// pair to `LSPVault.syncBacking` so EVM-side `getRate()` / `getSFlowQuote()` / `getFlowQuote()`
/// stay in sync with Cadence. Takes no arguments; safe to call repeatedly/idempotently.
transaction {
    prepare(_signer: &Account) {}
    execute {
        RelayerRouter.compoundAndSyncRate()
    }
}
