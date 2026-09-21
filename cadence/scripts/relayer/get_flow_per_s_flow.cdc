import "LiquidStaking"

access(all) fun main(): UInt256 {
    return LiquidStaking.flowPerSFlowScaled()
}
