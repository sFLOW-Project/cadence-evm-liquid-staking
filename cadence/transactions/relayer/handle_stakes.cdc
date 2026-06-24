import "FungibleToken"
import "FlowToken"
import "ScopedFTProviders"
import "RelayerRouter"

/// Fulfil one or more EVM-side stake requests by ID. For each ID, `RelayerRouter` pulls the
/// queued FLOW out of the LSPVault, runs `LiquidStaking.stake`, bridges the minted sFlow to
/// EVM, and either calls `fulfillStakeRequest` or `cancelStakeRequestSlippage` based on the
/// computed quote vs. `minAmountOut`.
///
/// Each successful fulfil triggers a Flow EVM bridge crossing, which charges a per-call FLOW
/// fee (`FlowEVMBridgeUtils.calculateBridgeFee`). The transaction wraps the signer's
/// `/storage/flowTokenVault` in a `ScopedFTProvider` capped at `maxBridgeFlowFee` to bound
/// the FLOW that may be debited.
///
/// Args:
///   - `stakeRequestIds`   EVM `stakeRequests(uint256)` IDs to process this batch
///   - `maxBridgeFlowFee`  hard upper bound on FLOW debited from the signer's vault
///                          across the whole batch (set generously above the bridge's
///                          current `baseFee + storageFee` per request)
transaction(stakeRequestIds: [UInt256], maxBridgeFlowFee: UFix64) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        let providerCap = signer.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)

        let scopedProvider <- ScopedFTProviders.createScopedFTProvider(
            provider: providerCap,
            filters: [ScopedFTProviders.AllowanceFilter(maxBridgeFlowFee)],
            expiration: getCurrentBlock().timestamp + 60.0
        )

        RelayerRouter.handleStakes(
            stakeRequestIds: stakeRequestIds,
            feeProvider: &scopedProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
        )

        destroy scopedProvider
    }
}
