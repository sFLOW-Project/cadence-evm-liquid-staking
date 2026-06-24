import "FlowIDTableStaking"

/// Flip the staking-mock's global `stakingEnabled` switch.
transaction(enabled: Bool) {
    prepare(signer: &Account) {}
    execute {
        FlowIDTableStaking.setStakingEnabled(enabled)
    }
}
