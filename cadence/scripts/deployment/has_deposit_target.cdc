import "LiquidStakingConfig"

/// True once at least one delegator slot has been registered (`register_protocol_delegator.cdc`
/// has run and `DelegatorSet` has a deposit target). Used by the deploy pipeline to decide
/// whether registration is still needed.
access(all) fun main(): Bool {
    return LiquidStakingConfig.getDepositTargetSlotId() != nil
}
