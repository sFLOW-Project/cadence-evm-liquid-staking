import "Burner"
import "FungibleToken"
import "MetadataViews"
import "FungibleTokenMetadataViews"

access(all) contract sFlowToken: FungibleToken {

    /// Minting requires an `auth(SFlowMint)` borrow on Minter; keep SFlowMint capability issuance limited in bootstrap.
    access(all) entitlement SFlowMint

    // Total supply of Flow tokens in existence
    access(all) var totalSupply: UFix64

    // Paths
    access(all) let tokenVaultPath: StoragePath
    access(all) let tokenBalancePath: PublicPath
    access(all) let tokenReceiverPath: PublicPath
    access(all) let minterStoragePath: StoragePath

    // Event that is emitted when tokens are withdrawn from a Vault
    access(all) event TokensWithdrawn(amount: UFix64, from: Address?)

    // Event that is emitted when tokens are deposited to a Vault
    access(all) event TokensDeposited(amount: UFix64, to: Address?)

    // Event that is emitted when new tokens are minted
    access(all) event TokensMinted(amount: UFix64)

    // Event that is emitted when tokens are destroyed
    access(all) event TokensBurned(amount: UFix64)

    // Vault
    //
    // Each user stores an instance of only the Vault in their storage
    // The functions in the Vault and governed by the pre and post conditions
    // in FungibleToken when they are called.
    // The checks happen at runtime whenever a function is called.
    //
    // Resources can only be created in the context of the contract that they
    // are defined in, so there is no way for a malicious user to create Vaults
    // out of thin air. A special Minter resource needs to be defined to mint
    // new tokens.
    access(all) resource Vault: FungibleToken.Vault {

        // holds the balance of a users tokens
        access(all) var balance: UFix64

        // initialize the balance at resource creation time
        init(balance: UFix64) {
            self.balance = balance
        }

        /// Called when this sFlow vault is burned via the `Burner.burn()` method
        access(contract) fun burnCallback() {
            if self.balance > 0.0 {
                emit TokensBurned(amount: self.balance)
                sFlowToken.totalSupply = sFlowToken.totalSupply - self.balance
            }
            self.balance = 0.0
        }

        /// getSupportedVaultTypes optionally returns a list of vault types that this receiver accepts
        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            return {self.getType(): true}
        }

        access(all) view fun isSupportedVaultType(type: Type): Bool {
            return type == self.getType()
        }

        /// Asks if the amount can be withdrawn from this vault
        access(all) view fun isAvailableToWithdraw(amount: UFix64): Bool {
            return amount <= self.balance
        }

        /// Added to conform to the new FT-V2 interface.
        access(all) view fun getViews(): [Type] {
            return sFlowToken.getContractViews(resourceType: nil)
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            return sFlowToken.resolveContractView(resourceType: nil, viewType: view)
        }

        // withdraw
        //
        // Function that takes an integer amount as an argument
        // and withdraws that amount from the Vault.
        // It creates a new temporary Vault that is used to hold
        // the money that is being transferred. It returns the newly
        // created Vault to the context that called so it can be deposited
        // elsewhere.
        access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
            self.balance = self.balance - amount
            emit TokensWithdrawn(amount: amount, from: self.owner?.address)
            return <-create Vault(balance: amount)
        }

        // deposit
        //
        // Function that takes a Vault object as an argument and adds
        // its balance to the balance of the owners Vault.
        // It is allowed to destroy the sent Vault because the Vault
        // was a temporary holder of the tokens. The Vault's balance has
        // been consumed and therefore can be destroyed.
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            let vault <- from as! @sFlowToken.Vault
            self.balance = self.balance + vault.balance
            emit TokensDeposited(amount: vault.balance, to: self.owner?.address)
            vault.balance = 0.0
            destroy vault
        }

        access(all) fun createEmptyVault(): @{FungibleToken.Vault} {
            return <-create Vault(balance: 0.0)
        }
    }

    // createEmptyVault
    //
    // Function that creates a new Vault with a balance of zero
    // and returns it to the calling context. A user must call this function
    // and store the returned Vault in their storage in order to allow their
    // account to be able to receive deposits of this token type.
    access(all) fun createEmptyVault(vaultType: Type): @sFlowToken.Vault {
        return <-create Vault(balance: 0.0)
    }

    /// Added to conform to the new FT-V2 interface.
    access(all) view fun getContractViews(resourceType: Type?): [Type] {
        return [
            Type<FungibleTokenMetadataViews.FTView>(),
            Type<FungibleTokenMetadataViews.FTDisplay>(),
            Type<FungibleTokenMetadataViews.FTVaultData>(),
            Type<FungibleTokenMetadataViews.TotalSupply>()
        ]
    }

    access(all) fun resolveContractView(resourceType: Type?, viewType: Type): AnyStruct? {
        switch viewType {
            case Type<FungibleTokenMetadataViews.FTView>():
                return FungibleTokenMetadataViews.FTView(
                    ftDisplay: self.resolveContractView(resourceType: nil, viewType: Type<FungibleTokenMetadataViews.FTDisplay>()) as! FungibleTokenMetadataViews.FTDisplay?,
                    ftVaultData: self.resolveContractView(resourceType: nil, viewType: Type<FungibleTokenMetadataViews.FTVaultData>()) as! FungibleTokenMetadataViews.FTVaultData?
                )
            case Type<FungibleTokenMetadataViews.FTDisplay>():
                return FungibleTokenMetadataViews.FTDisplay(
                    name: "Staked FLOW",
                    symbol: "sFlow",
                    description: "Liquid staking receipt token for liquid staking protocol. Each unit represents a claim on FLOW backing the pool (staking rewards accrue to the exchange rate). Not affiliated with any third-party sFlow deployment.",
                    externalURL: MetadataViews.ExternalURL(""),
                    logos: MetadataViews.Medias([]),
                    socials: {}
                )
            case Type<FungibleTokenMetadataViews.FTVaultData>():
                return FungibleTokenMetadataViews.FTVaultData(
                    storagePath: sFlowToken.tokenVaultPath,
                    receiverPath: sFlowToken.tokenReceiverPath,
                    metadataPath: sFlowToken.tokenBalancePath,
                    receiverLinkedType: Type<&{FungibleToken.Receiver, FungibleToken.Vault}>(),
                    metadataLinkedType: Type<&{FungibleToken.Balance, FungibleToken.Vault}>(),
                    createEmptyVaultFunction: (fun (): @{FungibleToken.Vault} {
                        let vaultRef = sFlowToken.account.storage.borrow<auth(FungibleToken.Withdraw) &sFlowToken.Vault>(from: sFlowToken.tokenVaultPath)
			                ?? panic("Could not borrow reference to the contract's Vault!")
                        return <- vaultRef.createEmptyVault()
                    })
                )
            case Type<FungibleTokenMetadataViews.TotalSupply>():
                return FungibleTokenMetadataViews.TotalSupply(totalSupply: sFlowToken.totalSupply)
        }
        return nil
    }

    // Mint tokens
    // Co-deployed contracts cannot call this directly; only Minter reaches it via SFlowMint.
    access(contract) fun mintTokens(amount: UFix64): @sFlowToken.Vault {
        pre {
            amount > 0.0: "Mint amount \(amount) must be > 0"
        }
        sFlowToken.totalSupply = sFlowToken.totalSupply + amount
        emit TokensMinted(amount: amount)
        return <-create Vault(balance: amount)
    }

    access(all) resource Minter {
        access(SFlowMint) fun mintTokens(amount: UFix64): @Vault {
            return <- sFlowToken.mintTokens(amount: amount)
        }
    }

    // Burn tokens
    //
    // $sFlow token will be burned in exchange for underlying $flow when user requests unstake from the liquid staking protocol
    // Note: totalSupply decrement and event emition happen in token vault's burnCallback()
    access(all) fun burnTokens(from: @sFlowToken.Vault) {
        Burner.burn(<-from)
    }

    init() {
        self.totalSupply = 0.0

        self.tokenVaultPath = /storage/sFlowTokenVault
        self.tokenReceiverPath = /public/sFlowTokenReceiver
        self.tokenBalancePath = /public/sFlowTokenBalance
        self.minterStoragePath = /storage/sFlowTokenMinter

        let minter <- create Minter()
        self.account.storage.save(<-minter, to: self.minterStoragePath)
        
        // Create the Vault with the total supply of tokens and save it in storage
        let vault <- create Vault(balance: self.totalSupply)
        self.account.storage.save(<-vault, to: self.tokenVaultPath)

        // Create a public capability to the stored Vault that only exposes
        // the `deposit` method through the `Receiver` interface
        self.account.capabilities.publish(
            self.account.capabilities.storage.issue<&{FungibleToken.Receiver}>(self.tokenVaultPath),
            at: self.tokenReceiverPath
        )

        // Create a public capability to the stored Vault that only exposes
        // the `balance` field through the `Balance` interface
        self.account.capabilities.publish(
            self.account.capabilities.storage.issue<&{FungibleToken.Balance}>(self.tokenVaultPath),
            at: self.tokenBalancePath
        )
    }
}