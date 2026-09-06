import "FungibleToken"
import "FlowToken"

/// Minimal reproduction of the SFL-05 capability lifecycle used by relayer transactions.
/// Issues a temporary storage capability on /storage/flowTokenVault, immediately deletes its
/// controller, and asserts the account's storage controller count is unchanged.
transaction {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, GetStorageCapabilityController) &Account) {
        let before = signer.capabilities.storage.getControllers(forPath: /storage/flowTokenVault).length

        let providerCap = signer.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &FlowToken.Vault>(/storage/flowTokenVault)

        // In the real relayer transactions the capability is wrapped in a ScopedFTProvider here
        // and destroyed before the controller is deleted. Deleting the controller is what
        // prevents storage-capability-controller leakage (SFL-05).
        let controller = signer.capabilities.storage.getController(byCapabilityID: providerCap.id)
            ?? panic("Could not find issued capability controller")
        controller.delete()

        let after = signer.capabilities.storage.getControllers(forPath: /storage/flowTokenVault).length
        assert(after == before, message: "Storage capability controller count changed after issue+delete")
    }
}
