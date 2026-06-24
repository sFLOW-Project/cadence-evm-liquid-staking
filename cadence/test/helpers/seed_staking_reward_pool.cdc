import "FungibleToken"
import "FlowToken"
import "FlowIDTableStaking"

/// Signer withdraws `amount` FLOW and seeds the staking mock's reward pool. Tests
/// call this once to fund subsequent `accrueRewards(...)` calls.
transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let vault = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Signer has no FlowToken vault at /storage/flowTokenVault")
        let funds <- vault.withdraw(amount: amount)
        FlowIDTableStaking.seedRewardPool(from: <-funds)
    }
}
