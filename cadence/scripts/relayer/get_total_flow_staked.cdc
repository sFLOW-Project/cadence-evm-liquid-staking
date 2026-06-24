import "LiquidStaking"

/// `LiquidStaking.totalFlowStaked`: the Cadence-tracked total FLOW the protocol controls
/// (committed + staked + compounded rewards - unstaked). Drives the relayer's "do we have
/// enough to fulfil" check before forwarding unstake FLOW to the LSPVault.
access(all) fun main(): UFix64 {
    return LiquidStaking.totalFlowStaked
}
