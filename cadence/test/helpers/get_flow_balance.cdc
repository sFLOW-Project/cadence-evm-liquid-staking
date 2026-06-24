import "FungibleToken"
import "FlowToken"

access(all)
fun main(address: Address): UFix64 {
    let cap = getAccount(address).capabilities
        .borrow<&{FungibleToken.Balance}>(/public/flowTokenBalance)
        ?? panic("No FLOW balance capability at /public/flowTokenBalance")
    return cap.balance
}
