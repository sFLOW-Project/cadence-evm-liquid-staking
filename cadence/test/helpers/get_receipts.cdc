import "LiquidStaking"

/// Returns the raw `getFlowReceiptInfos()` array (one dict per receipt) for the
/// public capability published at `LiquidStaking.FlowReceiptCollectionPublicPath`.
access(all)
fun main(address: Address): [AnyStruct] {
    let cap = getAccount(address).capabilities
        .borrow<&{LiquidStaking.FlowReceiptCollectionPublic}>(
            LiquidStaking.FlowReceiptCollectionPublicPath
        )
        ?? panic("No FlowReceiptCollection capability at user")
    return cap.getFlowReceiptInfos()
}
