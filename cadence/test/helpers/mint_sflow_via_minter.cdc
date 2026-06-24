import "FungibleToken"
import "sFlowToken"

/// Mint `amount` sFlow into the signer's own sFlow vault. Used directly by
/// `sFlowToken_test.cdc` to exercise the `Minter` resource without going
/// through `LiquidStaking.stake`. Signer must own the minter.
transaction(amount: UFix64) {
    let minter: auth(sFlowToken.SFlowMint) &sFlowToken.Minter
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue, Capabilities) &Account) {
        self.minter = signer.storage
            .borrow<auth(sFlowToken.SFlowMint) &sFlowToken.Minter>(from: sFlowToken.minterStoragePath)
            ?? panic("Signer is not the sFlow minter")
        self.receiver = signer.capabilities
            .borrow<&{FungibleToken.Receiver}>(sFlowToken.tokenReceiverPath)
            ?? panic("Signer has no sFlow receiver capability")
    }

    execute {
        let vault <- self.minter.mintTokens(amount: amount)
        self.receiver.deposit(from: <-vault)
    }
}
