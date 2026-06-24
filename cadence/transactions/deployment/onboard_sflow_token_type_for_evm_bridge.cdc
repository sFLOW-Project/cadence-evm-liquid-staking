import "FungibleToken"
import "FlowToken"
import "sFlowToken"
import "FlowEVMBridge"
import "FlowEVMBridgeConfig"
import "ScopedFTProviders"

/// Onboards `@sFlowToken.Vault` with the Flow EVM bridge so a bridged ERC-20 representation exists.
///
/// MUST run before installing `RelayerRouter` (its init precondition asserts onboarding is done
/// and stores the resulting EVM sFlow address).
///
/// Idempotent: if `FlowEVMBridge` says the type no longer requires onboarding, the transaction
/// is a no-op and consumes no bridge fee.
///
/// `maxOnboardFlowFee` caps the FLOW the bridge is authorised to pull from the signer's vault;
/// suggested value is at least `FlowEVMBridgeConfig.onboardFee` plus margin.
transaction(maxOnboardFlowFee: UFix64) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        let sFlowVaultType = Type<@sFlowToken.Vault>()

        if FlowEVMBridge.typeRequiresOnboarding(sFlowVaultType) != true {
            return
        }

        let providerCap = signer.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)

        let scopedProvider <- ScopedFTProviders.createScopedFTProvider(
            provider: providerCap,
            filters: [ScopedFTProviders.AllowanceFilter(maxOnboardFlowFee)],
            expiration: getCurrentBlock().timestamp + 60.0
        )

        FlowEVMBridge.onboardByType(
            sFlowVaultType,
            feeProvider: &scopedProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
        )

        destroy scopedProvider
    }
}
