import "FungibleToken"
import "FungibleTokenMetadataViews"
import "sFlowToken"

/// Resolve FTVaultData and verify both advertised linked types can be borrowed
/// from their public paths on the given contract account. The borrows themselves
/// are the assertions; returning true means both composite types were available.
access(all) fun main(contractAddress: Address): Bool {
    let vaultData = sFlowToken.resolveContractView(
        resourceType: nil,
        viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
    ) as! FungibleTokenMetadataViews.FTVaultData?
        ?? panic("FTVaultData missing")

    let account = getAccount(contractAddress)

    let receiverCap = account.capabilities.get<&{FungibleToken.Receiver, FungibleToken.Vault}>(
        vaultData.receiverPath
    )
    let receiverRef = receiverCap.borrow() ?? panic("Could not borrow advertised receiver type")

    let balanceCap = account.capabilities.get<&{FungibleToken.Balance, FungibleToken.Vault}>(
        vaultData.metadataPath
    )
    let balanceRef = balanceCap.borrow() ?? panic("Could not borrow advertised metadata type")

    return true
}
