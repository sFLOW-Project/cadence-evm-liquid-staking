import "LiquidStakingConfig"

/// Returns a structured snapshot of every governable parameter on `LiquidStakingConfig`.
/// Order matches what off-chain tooling expects:
///   `{ "receiver", "feePercent", "feeQueued", "timelockExpiration", "paused", "minOp", "delay" }`.
access(all) fun main(): {String: AnyStruct} {
    return {
        "receiver": LiquidStakingConfig.protocolFeeReceiver,
        "feePercent": LiquidStakingConfig.protocolFeePercent,
        "feeQueued": LiquidStakingConfig.protocolFeePercentQueued,
        "timelockExpiration": LiquidStakingConfig.protocolFeeTimelockExpiration,
        "paused": LiquidStakingConfig.isStakingPaused,
        "minOp": LiquidStakingConfig.minOperationAmount,
        "delay": LiquidStakingConfig.unstakeUnlockEpochDelay
    }
}
