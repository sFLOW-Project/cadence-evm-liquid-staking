import "FungibleToken"
import "FlowToken"
import "ScopedFTProviders"
import "RelayerRouter"

/// Initiate one or more EVM-side unstake requests by ID. For each ID, `RelayerRouter` pulls
/// the queued bridged sFlow back from the LSPVault into a Cadence `@sFlowToken.Vault`,
/// invokes `LiquidStaking.unstake`, persists the resulting `FlowReceipt` under the
/// `evmRequestIdToReceipt` map (keyed by `unstakeRequestId`), and tells the EVM peer the
/// `unlockEpoch` via `confirmUnstakeRequest`. Finalisation happens later via
/// `finalize_unstakes.cdc` once the unlock epoch is crossed on Cadence.
///
/// Each bridged sFlow withdraw crosses the Flow EVM bridge and incurs a FLOW fee; bound it
/// with `maxBridgeFlowFee`, same scoping pattern as `handle_stakes.cdc`.
transaction(unstakeRequestIds: [UInt256], maxBridgeFlowFee: UFix64) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        let providerCap = signer.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)

        let scopedProvider <- ScopedFTProviders.createScopedFTProvider(
            provider: providerCap,
            filters: [ScopedFTProviders.AllowanceFilter(maxBridgeFlowFee)],
            expiration: getCurrentBlock().timestamp + 60.0
        )

        RelayerRouter.initiateUnstakes(
            unstakeRequestIds: unstakeRequestIds,
            feeProvider: &scopedProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
        )

        destroy scopedProvider
    }
}
