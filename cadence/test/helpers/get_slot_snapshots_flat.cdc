import "LiquidStakingConfig"

/// Per-slot snapshot as flat arrays for tests:
/// `[slotId, status, pendingClaims, committed, staked, unstaking, unstaked, rewarded]`
/// for each slot, concatenated.
access(all)
fun main(): [UFix64] {
    let snaps = LiquidStakingConfig.getSlotSnapshots()
    var out: [UFix64] = []
    var i = 0
    while i < snaps.length {
        let s = snaps[i]
        out.append(UFix64(s.slotId))
        out.append(UFix64(s.status))
        out.append(s.pendingClaims)
        out.append(s.tokensCommitted)
        out.append(s.tokensStaked)
        out.append(s.tokensUnstaking)
        out.append(s.tokensUnstaked)
        out.append(s.tokensRewarded)
        i = i + 1
    }
    return out
}
