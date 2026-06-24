import "LiquidStaking"
import "sFlowToken"

/// Aggregate protocol gauges used by dashboards / off-chain rate sanity checks.
///
/// `flowPerSFlow` / `sFlowPerFlow` are derived view functions on `LiquidStaking` (they read
/// `totalFlowStaked` and `sFlowToken.totalSupply`). They both return `1.0` when the protocol
/// is empty (no supply or no backing) so the script never panics.
access(all) fun main(): {String: UFix64} {
    return {
        "totalFlowStaked": LiquidStaking.totalFlowStaked,
        "sFlowTotalSupply": sFlowToken.totalSupply,
        "flowPerSFlow": LiquidStaking.flowPerSFlow(),
        "sFlowPerFlow": LiquidStaking.sFlowPerFlow()
    }
}
