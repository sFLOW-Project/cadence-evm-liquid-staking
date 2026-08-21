import "LiquidStakingConfig"

/// Returns bucket fields for one slot id:
/// `[status, pendingClaims, committed, staked, unstaking, unstaked, rewarded]`
access(all)
fun main(slotId: UInt64): [UFix64] {
    let snaps = LiquidStakingConfig.getSlotSnapshots()
    var i = 0
    while i < snaps.length {
        let s = snaps[i]
        if s.slotId == slotId {
            return [
                UFix64(s.status),
                s.pendingClaims,
                s.tokensCommitted,
                s.tokensStaked,
                s.tokensUnstaking,
                s.tokensUnstaked,
                s.tokensRewarded
            ]
        }
        i = i + 1
    }
    panic("slot \(slotId) not found")
}
