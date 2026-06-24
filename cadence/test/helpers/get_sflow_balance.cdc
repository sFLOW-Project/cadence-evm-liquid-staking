import "FungibleToken"
import "sFlowToken"

access(all)
fun main(address: Address): UFix64 {
    let cap = getAccount(address).capabilities
        .borrow<&{FungibleToken.Balance}>(sFlowToken.tokenBalancePath)
        ?? panic("No sFlow balance capability")
    return cap.balance
}
