import "LiquidStakingConfig"

access(all) fun main(): {String: AnyStruct} {
    return {
        "delay": LiquidStakingConfig.unstakeUnlockEpochDelay
    }
}

