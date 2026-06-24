import "FungibleToken"
import "FlowToken"
import "sFlowToken"

/// Idempotently provisions the protocol account with:
///   - a `@FlowToken.Vault` at `/storage/flowTokenVault`
///   - a `&{FungibleToken.Receiver}` capability at `/public/flowTokenReceiver`
///     (required: `LiquidStaking.compoundRewards()` deposits the protocol fee
///     here when `protocolFeeReceiver == this account`)
///   - a `&{FungibleToken.Balance}` capability at `/public/flowTokenBalance`
///   - a `@sFlowToken.Vault` at `sFlowToken.tokenVaultPath`
///     (required: `RelayerRouter.initiateUnstakeInternal` deposits bridged sFlow into it)
///   - matching interface-typed Receiver / Balance public caps for sFlow
///
/// Safe to re-run; existing storage and capabilities are reused.
transaction {
    prepare(signer: auth(SaveValue, BorrowValue, Capabilities, UnpublishCapability) &Account) {
        // FLOW vault
        if signer.storage.borrow<&FlowToken.Vault>(from: /storage/flowTokenVault) == nil {
            signer.storage.save(
                <-FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()),
                to: /storage/flowTokenVault
            )
        }
        let _oldFlowRecv = signer.capabilities.unpublish(/public/flowTokenReceiver)
        let flowRecvCap = signer.capabilities.storage
            .issue<&{FungibleToken.Receiver}>(/storage/flowTokenVault)
        signer.capabilities.publish(flowRecvCap, at: /public/flowTokenReceiver)

        let _oldFlowBal = signer.capabilities.unpublish(/public/flowTokenBalance)
        let flowBalCap = signer.capabilities.storage
            .issue<&{FungibleToken.Balance}>(/storage/flowTokenVault)
        signer.capabilities.publish(flowBalCap, at: /public/flowTokenBalance)

        // sFlow vault (only created after sFlowToken contract is installed)
        if signer.storage.borrow<&sFlowToken.Vault>(from: sFlowToken.tokenVaultPath) == nil {
            signer.storage.save(
                <-sFlowToken.createEmptyVault(vaultType: Type<@sFlowToken.Vault>()),
                to: sFlowToken.tokenVaultPath
            )
        }
        let _oldStRecv = signer.capabilities.unpublish(sFlowToken.tokenReceiverPath)
        let stRecvCap = signer.capabilities.storage
            .issue<&{FungibleToken.Receiver}>(sFlowToken.tokenVaultPath)
        signer.capabilities.publish(stRecvCap, at: sFlowToken.tokenReceiverPath)

        let _oldStBal = signer.capabilities.unpublish(sFlowToken.tokenBalancePath)
        let stBalCap = signer.capabilities.storage
            .issue<&{FungibleToken.Balance}>(sFlowToken.tokenVaultPath)
        signer.capabilities.publish(stBalCap, at: sFlowToken.tokenBalancePath)
    }
}
