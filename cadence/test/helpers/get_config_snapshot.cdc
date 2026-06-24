import "LiquidStakingConfig"

/// Read-only snapshot of the LSP config fields that mutate during admin tests.
/// Layout (positional):
///   [0] protocolFeeReceiver: Address
///   [1] protocolFeePercent: UFix64
///   [2] protocolFeePercentQueued: UFix64?
///   [3] protocolFeeTimelockExpiration: UInt64
///   [4] isStakingPaused: Bool
///   [5] minOperationAmount: UFix64
///   [6] unstakeUnlockEpochDelay: UInt64
access(all)
fun main(): [AnyStruct] {
    return [
        LiquidStakingConfig.protocolFeeReceiver,
        LiquidStakingConfig.protocolFeePercent,
        LiquidStakingConfig.protocolFeePercentQueued,
        LiquidStakingConfig.protocolFeeTimelockExpiration,
        LiquidStakingConfig.isStakingPaused,
        LiquidStakingConfig.minOperationAmount,
        LiquidStakingConfig.unstakeUnlockEpochDelay
    ]
}
