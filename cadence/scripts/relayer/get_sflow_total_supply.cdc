import "sFlowToken"

/// `sFlowToken.totalSupply` - the supply side of the `flowPerSFlow` ratio and the value the
/// relayer cross-checks against the bridged ERC-20 total supply on EVM.
access(all) fun main(): UFix64 {
    return sFlowToken.totalSupply
}
