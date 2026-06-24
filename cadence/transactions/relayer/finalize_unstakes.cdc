import "RelayerRouter"

/// Settle one or more previously-initiated EVM unstake requests whose `unlockEpoch` has
/// already been crossed on Cadence. For each ID, `RelayerRouter` reclaims the FlowReceipt
/// stored on initiation, calls `LiquidStaking.withdraw`, deposits the FLOW back into the
/// router's COA, forwards it as native value to the LSPVault, and finally calls
/// `fulfillUnstakeRequest` on EVM.
///
/// No bridge crossing happens here (everything flows over EVM-native value transfers), so no
/// fee provider is required.
transaction(unstakeRequestIds: [UInt256]) {
    prepare(_signer: &Account) {}
    execute {
        RelayerRouter.finalizeUnstakes(unstakeRequestIds: unstakeRequestIds)
    }
}
