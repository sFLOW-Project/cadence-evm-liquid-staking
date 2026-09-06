import "LiquidStaking"
import "sFlowToken"

/// Aggregate protocol gauges used by dashboards / off-chain rate sanity checks.
///
/// `flowPerSFlowScaled` is the canonical rate (1e18). `UFix64` rate views are display-only.
access(all) fun main(): {String: AnyStruct} {
    return {
        "totalFlowStaked": LiquidStaking.totalFlowStaked,
        "sFlowTotalSupply": sFlowToken.totalSupply,
        "protocolOwnedSFlow": LiquidStaking.protocolOwnedSFlowBalance(),
        "flowPerSFlowScaled": LiquidStaking.flowPerSFlowScaled(),
        "sFlowPerFlowScaled": LiquidStaking.sFlowPerFlowScaled()
    }
}
