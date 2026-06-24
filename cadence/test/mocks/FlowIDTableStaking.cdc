import "FungibleToken"
import "FlowToken"

/// Test-only mock for Flow's `FlowIDTableStaking` system contract.
///
/// Re-implements only the surface that `LiquidStaking.cdc` and
/// `LiquidStakingConfig.Admin.registerDelegator(...)` rely on:
///   - `entitlement DelegatorOwner`
///   - `view fun stakingEnabled(): Bool`
///   - `fun registerNewDelegator(nodeID, tokensCommitted): @NodeDelegator`
///   - `resource NodeDelegator { delegateNewTokens, requestUnstaking, withdrawUnstakedTokens, withdrawRewardedTokens, delegateRewardedTokens }`
///   - `struct DelegatorInfo(nodeID, delegatorID) { tokensCommitted, tokensStaked, tokensUnstaking, tokensUnstaked, tokensRewarded, tokensRequestedToUnstake }`
///
/// Plus test-only knobs so `flow test` can drive lifecycle deterministically:
///   - `setStakingEnabled(_:)` flips the global pause used by `LiquidStaking`'s preconditions
///   - `seedRewardPool(from:)` deposits FLOW the contract can later credit as rewards
///   - `accrueRewards(nodeID, delegatorID, amount)` increases a delegator's `rewarded` bucket
///   - `matureUnstaking(nodeID, delegatorID)` / `matureAllUnstaking()` move `unstaking` → `unstaked`
access(all) contract FlowIDTableStaking {

    access(all) entitlement DelegatorOwner

    access(all) event DelegatorRegistered(nodeID: String, delegatorID: UInt32, committedAmount: UFix64)
    access(all) event RewardsAccrued(nodeID: String, delegatorID: UInt32, amount: UFix64)
    access(all) event UnstakingMatured(nodeID: String, delegatorID: UInt32, amount: UFix64)
    access(all) event RewardPoolSeeded(amount: UFix64)

    access(self) var stakingOn: Bool
    access(self) var nextDelegatorId: UInt32
    access(self) let buckets: @{String: DelegatorBuckets}
    access(self) let rewardPool: @FlowToken.Vault

    access(all) view fun bucketKey(nodeID: String, delegatorID: UInt32): String {
        return nodeID.concat("|").concat(delegatorID.toString())
    }

    /// Per-delegator state. Bucket balances are tracked as UFix64; all FLOW for one
    /// delegator sits in a single consolidated `vault` to keep the mock simple.
    access(all) resource DelegatorBuckets {
        access(all) var committed: UFix64
        access(all) var staked: UFix64
        access(all) var unstaking: UFix64
        access(all) var unstaked: UFix64
        access(all) var rewarded: UFix64
        access(self) let vault: @FlowToken.Vault

        access(contract) fun depositCommitted(_ flow: @{FungibleToken.Vault}) {
            let amount = flow.balance
            self.committed = self.committed + amount
            self.vault.deposit(from: <-flow)
        }

        access(contract) fun moveAllCommittedToStaked() {
            self.staked = self.staked + self.committed
            self.committed = 0.0
        }

        access(contract) fun moveStakedToUnstaking(amount: UFix64) {
            let avail = self.staked + self.committed
            assert(amount <= avail, message: "Insufficient staked/committed balance to unstake")
            let fromStaked = amount > self.staked ? self.staked : amount
            let fromCommitted = amount - fromStaked
            self.staked = self.staked - fromStaked
            self.committed = self.committed - fromCommitted
            self.unstaking = self.unstaking + amount
        }

        access(contract) fun matureUnstaking(): UFix64 {
            let amount = self.unstaking
            if amount == 0.0 {
                return 0.0
            }
            self.unstaking = 0.0
            self.unstaked = self.unstaked + amount
            return amount
        }

        access(contract) fun pullUnstaked(amount: UFix64): @{FungibleToken.Vault} {
            assert(amount <= self.unstaked, message: "Insufficient unstaked balance")
            self.unstaked = self.unstaked - amount
            return <- self.vault.withdraw(amount: amount)
        }

        access(contract) fun pullRewarded(amount: UFix64): @{FungibleToken.Vault} {
            assert(amount <= self.rewarded, message: "Insufficient rewarded balance")
            self.rewarded = self.rewarded - amount
            return <- self.vault.withdraw(amount: amount)
        }

        access(contract) fun moveRewardedToStaked(amount: UFix64) {
            assert(amount <= self.rewarded, message: "Insufficient rewarded balance to delegate")
            self.rewarded = self.rewarded - amount
            self.staked = self.staked + amount
        }

        access(contract) fun creditReward(from: @{FungibleToken.Vault}) {
            let amount = from.balance
            self.rewarded = self.rewarded + amount
            self.vault.deposit(from: <-from)
        }

        init() {
            self.committed = 0.0
            self.staked = 0.0
            self.unstaking = 0.0
            self.unstaked = 0.0
            self.rewarded = 0.0
            self.vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()) as! @FlowToken.Vault
        }
    }

    /// Resource handed out by `registerNewDelegator(...)`. Stored by the protocol at
    /// `LiquidStakingConfig.DelegatorStoragePath`. All mutators require `DelegatorOwner`
    /// entitlement, mirroring real Flow staking.
    access(all) resource NodeDelegator {
        access(all) let id: UInt32
        access(all) let nodeID: String

        access(DelegatorOwner) fun delegateNewTokens(from: @{FungibleToken.Vault}) {
            FlowIDTableStaking.depositCommittedInternal(nodeID: self.nodeID, delegatorID: self.id, from: <-from)
        }

        access(DelegatorOwner) fun requestUnstaking(amount: UFix64) {
            FlowIDTableStaking.requestUnstakingInternal(nodeID: self.nodeID, delegatorID: self.id, amount: amount)
        }

        access(DelegatorOwner) fun withdrawUnstakedTokens(amount: UFix64): @{FungibleToken.Vault} {
            return <- FlowIDTableStaking.pullUnstakedInternal(nodeID: self.nodeID, delegatorID: self.id, amount: amount)
        }

        access(DelegatorOwner) fun withdrawRewardedTokens(amount: UFix64): @{FungibleToken.Vault} {
            return <- FlowIDTableStaking.pullRewardedInternal(nodeID: self.nodeID, delegatorID: self.id, amount: amount)
        }

        access(DelegatorOwner) fun delegateRewardedTokens(amount: UFix64) {
            FlowIDTableStaking.moveRewardedToStakedInternal(nodeID: self.nodeID, delegatorID: self.id, amount: amount)
        }

        init(id: UInt32, nodeID: String) {
            self.id = id
            self.nodeID = nodeID
        }
    }

    /// Read-only snapshot of a delegator's buckets, identified by `(nodeID, delegatorID)`.
    access(all) struct DelegatorInfo {
        access(all) let nodeID: String
        access(all) let id: UInt32
        access(all) let tokensCommitted: UFix64
        access(all) let tokensStaked: UFix64
        access(all) let tokensUnstaking: UFix64
        access(all) let tokensUnstaked: UFix64
        access(all) let tokensRewarded: UFix64
        access(all) let tokensRequestedToUnstake: UFix64

        init(nodeID: String, delegatorID: UInt32) {
            let key = FlowIDTableStaking.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
            let bucket = FlowIDTableStaking.borrowBucket(key: key)
                ?? panic("delegator not found for nodeID/delegatorID")
            self.nodeID = nodeID
            self.id = delegatorID
            self.tokensCommitted = bucket.committed
            self.tokensStaked = bucket.staked
            self.tokensUnstaking = bucket.unstaking
            self.tokensUnstaked = bucket.unstaked
            self.tokensRewarded = bucket.rewarded
            self.tokensRequestedToUnstake = bucket.unstaking
        }
    }

    // ---- production-facing API used by LiquidStaking / LiquidStakingConfig ----

    access(all) view fun stakingEnabled(): Bool {
        return self.stakingOn
    }

    access(all) fun registerNewDelegator(nodeID: String, tokensCommitted: @FlowToken.Vault): @NodeDelegator {
        let id = self.nextDelegatorId
        self.nextDelegatorId = id + 1
        let committed = tokensCommitted.balance
        let bucket <- create DelegatorBuckets()
        bucket.depositCommitted(<-(tokensCommitted as @{FungibleToken.Vault}))
        // The mock treats committed funds as immediately staked. The production contract
        // only moves them after a successful epoch-end heartbeat; we collapse that step so
        // tests don't have to wait for an epoch flip just to see staked principal.
        bucket.moveAllCommittedToStaked()
        let key = self.bucketKey(nodeID: nodeID, delegatorID: id)
        let prev <- self.buckets.insert(key: key, <-bucket)
        destroy prev
        emit DelegatorRegistered(nodeID: nodeID, delegatorID: id, committedAmount: committed)
        return <- create NodeDelegator(id: id, nodeID: nodeID)
    }

    // ---- test-only helpers ----

    access(all) fun setStakingEnabled(_ enabled: Bool) {
        self.stakingOn = enabled
    }

    /// Seed the contract with FLOW that later `accrueRewards(...)` calls can credit
    /// into delegator `rewarded` buckets.
    access(all) fun seedRewardPool(from: @{FungibleToken.Vault}) {
        let amount = from.balance
        self.rewardPool.deposit(from: <-from)
        emit RewardPoolSeeded(amount: amount)
    }

    /// Credit `amount` FLOW from the pool into the delegator's `rewarded` bucket. The
    /// `LiquidStaking.compoundRewards()` path then reads this via `DelegatorInfo.tokensRewarded`.
    access(all) fun accrueRewards(nodeID: String, delegatorID: UInt32, amount: UFix64) {
        assert(amount > 0.0, message: "amount must be positive")
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        let funds <- self.rewardPool.withdraw(amount: amount)
        bucket.creditReward(from: <-funds)
        emit RewardsAccrued(nodeID: nodeID, delegatorID: delegatorID, amount: amount)
    }

    /// Move one delegator's entire `unstaking` balance into `unstaked` (epoch tick).
    access(all) fun matureUnstaking(nodeID: String, delegatorID: UInt32) {
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        let amount = bucket.matureUnstaking()
        if amount > 0.0 {
            emit UnstakingMatured(nodeID: nodeID, delegatorID: delegatorID, amount: amount)
        }
    }

    /// Mature every delegator's `unstaking` bucket in one shot.
    access(all) fun matureAllUnstaking() {
        for key in self.buckets.keys {
            let bucket = self.borrowBucket(key: key) ?? panic("missing bucket")
            let _ = bucket.matureUnstaking()
        }
    }

    /// Current reward-pool balance (used by tests for sanity).
    access(all) view fun rewardPoolBalance(): UFix64 {
        return self.rewardPool.balance
    }

    // ---- internals (called from the inner NodeDelegator resource) ----

    access(contract) fun depositCommittedInternal(nodeID: String, delegatorID: UInt32, from: @{FungibleToken.Vault}) {
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        bucket.depositCommitted(<-from)
        bucket.moveAllCommittedToStaked()
    }

    access(contract) fun requestUnstakingInternal(nodeID: String, delegatorID: UInt32, amount: UFix64) {
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        bucket.moveStakedToUnstaking(amount: amount)
    }

    access(contract) fun pullUnstakedInternal(nodeID: String, delegatorID: UInt32, amount: UFix64): @{FungibleToken.Vault} {
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        return <- bucket.pullUnstaked(amount: amount)
    }

    access(contract) fun pullRewardedInternal(nodeID: String, delegatorID: UInt32, amount: UFix64): @{FungibleToken.Vault} {
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        return <- bucket.pullRewarded(amount: amount)
    }

    access(contract) fun moveRewardedToStakedInternal(nodeID: String, delegatorID: UInt32, amount: UFix64) {
        let key = self.bucketKey(nodeID: nodeID, delegatorID: delegatorID)
        let bucket = self.borrowBucket(key: key) ?? panic("delegator not found")
        bucket.moveRewardedToStaked(amount: amount)
    }

    access(contract) view fun borrowBucket(key: String): &DelegatorBuckets? {
        return &self.buckets[key]
    }

    init() {
        self.stakingOn = true
        self.nextDelegatorId = 1
        self.buckets <- {}
        self.rewardPool <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()) as! @FlowToken.Vault
    }
}
