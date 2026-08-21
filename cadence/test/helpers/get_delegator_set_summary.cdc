import "LiquidStakingConfig"

/// Returns `{ "depositTarget": UInt64?, "pending": UFix64, "slotCount": Int }`.
access(all)
fun main(): {String: AnyStruct} {
    return {
        "depositTarget": LiquidStakingConfig.getDepositTargetSlotId(),
        "pending": LiquidStakingConfig.getTotalPendingWithdrawal(),
        "slotCount": LiquidStakingConfig.getSlotSnapshots().length
    }
}
