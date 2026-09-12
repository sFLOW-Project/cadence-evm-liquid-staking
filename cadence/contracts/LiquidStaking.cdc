import "FungibleToken"
import "FlowToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "LiquidStakingConfig"
import "EVMRoute"
import "sFlowToken"

/// Liquid staking contract on Flow.
///
access(all) contract LiquidStaking {
    /// User **`FlowReceipt`** storage from **`unstake`** and optional public capability for indexing.
    access(all) let FlowReceiptCollectionPath: StoragePath
    access(all) let FlowReceiptCollectionPublicPath: PublicPath

    /// Total FLOW the protocol controls (staked + committed + compounded rewards − unstaked).
    access(all) var totalFlowStaked: UFix64

    /// Total FLOW amount currently locked in outstanding `FlowReceipt` resources.
    /// Used to block `realizeLoss` while fixed-receipt claims exist.
    access(all) var totalFlowReceiptsOutstanding: UFix64

    /// Permanently locked protocol-owned sFLOW. Seeded once with matching FLOW backing so
    /// `totalSupply` cannot be burned down to a UFix64 dust amount (SFL-01).
    access(all) let protocolOwnedSFlowFloor: UFix64
    access(self) let protocolOwnedSFlow: @sFlowToken.Vault

    access(all) event Staked(flowAmount: UFix64, sFlowAmount: UFix64)
    access(all) event ProtocolOwnedSFlowSeeded(flowAmount: UFix64, sFlowAmount: UFix64)
    access(all) event UnstakeRequested(id: UInt64, sFlowAmount: UFix64, flowAmount: UFix64, unlockEpoch: UInt64)
    access(all) event UnstakeFulfilled(id: UInt64, flowAmount: UFix64)
    access(all) event UnstakeFlowRoutedToEvm(id: UInt64, flowAmount: UFix64)
    access(all) event LossRealized(amount: UFix64, totalFlowStaked: UFix64)
    access(all) event RewardsCompounded(rewardAmount: UFix64, feeAmount: UFix64)
    access(all) event FlowReceiptDeposited(id: UInt64, flowAmount: UFix64, unlockEpoch: UInt64, owner: Address?)
    access(all) event FlowReceiptWithdrawn(id: UInt64, flowAmount: UFix64, unlockEpoch: UInt64, owner: Address?)

    /// Bearer resource proving the holder is owed `amount` FLOW after `unlockEpoch`.
    /// Destroying this resource outside the protocol `withdraw` / `withdrawStuckReceipt`
    /// paths forfeits the withdrawal credential: the underlying FLOW and the slot's
    /// `pendingClaims` remain in the protocol, but no one can present the receipt to
    /// withdraw them. This is an accepted design limitation, not a recoverable error.
    access(all) resource FlowReceipt {
        access(all) let amount: UFix64
        access(all) let unlockEpoch: UInt64

        init(amount: UFix64, unlockEpoch: UInt64) {
            self.amount = amount
            self.unlockEpoch = unlockEpoch
        }
    }

    access(all) view fun protocolOwnedSFlowBalance(): UFix64 {
        return self.protocolOwnedSFlow.balance
    }

    access(all) view fun isProtocolOwnedSFlowSeeded(): Bool {
        return self.protocolOwnedSFlow.balance >= self.protocolOwnedSFlowFloor
    }

    /// Stake `protocolOwnedSFlowFloor` FLOW once and lock the minted sFLOW in this contract.
    /// Rate stays 1.0 after seed; user deposits are not diluted.
    access(all) fun seedProtocolOwnedSFlow(from: @FlowToken.Vault) {
        pre {
            !self.isProtocolOwnedSFlowSeeded():
                "Protocol-owned sFLOW floor already seeded"
            from.balance == self.protocolOwnedSFlowFloor:
                "Seed FLOW amount \(from.balance) must equal floor \(self.protocolOwnedSFlowFloor)"
            LiquidStakingConfig.isStakingPaused == false: "Staking is paused"
            FlowIDTableStaking.stakingEnabled() == true: "Not in the Flow chain staking period"
        }

        let flowAmount = from.balance
        let minted <- self.mintSFlowForFlow(from: <-from)
        let sFlowAmount = minted.balance
        self.protocolOwnedSFlow.deposit(from: <-minted)
        emit ProtocolOwnedSFlowSeeded(flowAmount: flowAmount, sFlowAmount: sFlowAmount)
    }

    access(all) fun stake(from: @FlowToken.Vault): @sFlowToken.Vault {
        pre {
            self.isProtocolOwnedSFlowSeeded():
                "Protocol-owned sFLOW floor not seeded"
            LiquidStakingConfig.isStakingPaused == false: "Staking is paused"
            FlowIDTableStaking.stakingEnabled() == true: "Not in the Flow chain staking period"
            from.balance >= LiquidStakingConfig.minOperationAmount:
                "Stake amount \(from.balance) must be >= min \(LiquidStakingConfig.minOperationAmount)"
        }

        return <- self.mintSFlowForFlow(from: <-from)
    }

    access(self) fun mintSFlowForFlow(from: @FlowToken.Vault): @sFlowToken.Vault {
        let flowAmount = from.balance
        let sFlowAmount = self.calcSFlowFromFlow(flowAmount: flowAmount)
        assert(
            sFlowAmount > 0.0,
            message: "Stake FLOW amount \(flowAmount) mints 0 sFlow at current backing/supply"
        )

        // Manager: commit onto Active deposit-target delegator
        LiquidStakingConfig.depositToCommitted(from: <-from)

        self.totalFlowStaked = self.totalFlowStaked + flowAmount

        emit Staked(flowAmount: flowAmount, sFlowAmount: sFlowAmount)

        let minter = self.account.storage.borrow<auth(sFlowToken.SFlowMint) &sFlowToken.Minter>(
            from: sFlowToken.minterStoragePath
        ) ?? panic("sFlow minter not found")

        return <- minter.mintTokens(amount: sFlowAmount)
    }

    access(all) fun unstake(from: @sFlowToken.Vault): @FlowReceipt {
        pre {
            FlowIDTableStaking.stakingEnabled() == true: "Not in the Flow chain staking period"
            LiquidStakingConfig.isUnstakingPaused == false: "Unstaking is paused"
        }

        let sFlowAmount = from.balance
        let flowAmount = self.calcFlowFromSFlow(sFlowAmount: sFlowAmount)
        assert(
            flowAmount >= LiquidStakingConfig.minOperationAmount,
            message: "Unstake FLOW amount \(flowAmount) must be >= min \(LiquidStakingConfig.minOperationAmount)"
        )

        sFlowToken.burnTokens(from: <-from)

        // Manager: reserve / request FLOW across DelegatorSet slots
        let allocation = LiquidStakingConfig.requestWithdrawFromStaked(amount: flowAmount)

        self.totalFlowStaked = self.totalFlowStaked - flowAmount

        let receipt <- create FlowReceipt(
            amount: flowAmount,
            unlockEpoch: allocation.unlockEpoch
        )
        self.totalFlowReceiptsOutstanding = self.totalFlowReceiptsOutstanding + flowAmount
        LiquidStakingConfig.bindWithdrawClaim(
            ticketId: allocation.ticketId,
            receiptUuid: receipt.uuid
        )

        emit UnstakeRequested(
            id: receipt.uuid,
            sFlowAmount: sFlowAmount,
            flowAmount: flowAmount,
            unlockEpoch: allocation.unlockEpoch
        )

        return <- receipt
    }

    /// Cash out a matured `FlowReceipt` from the manager's unstaked buckets.
    access(all) fun withdraw(receipt: @FlowReceipt): @FlowToken.Vault {
        pre {
            /// Setting unstakeUnlockEpochDelay allows admin to apply delay to the currently pending requests
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch + LiquidStakingConfig.unstakeUnlockEpochDelay:
                "Unstake not unlocked: epoch \(FlowEpoch.currentEpochCounter) < unlock \(receipt.unlockEpoch) + delay \(LiquidStakingConfig.unstakeUnlockEpochDelay)"
        }

        emit UnstakeFulfilled(id: receipt.uuid, flowAmount: receipt.amount)

        let flowVault <- LiquidStakingConfig.withdrawFromUnstaked(
            receiptUuid: receipt.uuid,
            amount: receipt.amount
        )

        self.totalFlowReceiptsOutstanding = self.totalFlowReceiptsOutstanding - receipt.amount
        destroy receipt

        return <- flowVault
    }

    /// Admin recovery withdraw for stuck EVM unstake receipts (`RelayerRouter.evictStuckReceipt`).
    /// Differs from `withdraw`:
    ///   - Honors base `receipt.unlockEpoch` only (ignores retroactive `unstakeUnlockEpochDelay`).
    ///   - Pulls available unstaked FLOW across claim legs when buckets are short.
    ///   - Credits `receipt.amount - withdrawAmount` back to `totalFlowStaked`.
    /// The returned vault balance is the amount EVM must credit (`fulfillUnstakeRequestPartial`
    /// when it is less than `receipt.amount`). The Cadence receipt is always destroyed.
    access(account) fun withdrawStuckReceipt(receipt: @FlowReceipt): @FlowToken.Vault {
        pre {
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch:
                "Base unstake unlock epoch not reached: epoch \(FlowEpoch.currentEpochCounter) < \(receipt.unlockEpoch)"
        }

        let requested = receipt.amount
        let flowVault <- LiquidStakingConfig.withdrawFromUnstakedPartial(
            receiptUuid: receipt.uuid,
            amount: requested
        )
        let withdrawAmount = flowVault.balance

        emit UnstakeFulfilled(id: receipt.uuid, flowAmount: withdrawAmount)

        self.totalFlowStaked = self.totalFlowStaked + (requested - withdrawAmount)
        self.totalFlowReceiptsOutstanding = self.totalFlowReceiptsOutstanding - requested

        destroy receipt

        return <- flowVault
    }

    /// Governance-only loss realization. Permanently reduces `totalFlowStaked` when a
    /// genuine, unrecoverable slashing loss has been confirmed. The loss is bounded by
    /// the verifiable shortfall between `totalFlowStaked` and the actual FLOW currently
    /// held across all protocol delegator slots (read from `FlowIDTableStaking`). This
    /// prevents phantom backing and limits admin discretion. Caller must hold the
    /// protocol `LiquidStakingConfig.Admin` resource.
    access(all) fun realizeLoss(amount: UFix64, admin: &LiquidStakingConfig.Admin) {
        pre {
            amount > 0.0: "Loss amount must be positive"
            amount <= self.totalFlowStaked: "Loss \(amount) exceeds totalFlowStaked \(self.totalFlowStaked)"
            self.totalFlowReceiptsOutstanding == 0.0:
                "Cannot realize loss while FlowReceipts are outstanding: \(self.totalFlowReceiptsOutstanding) FLOW"
        }

        let actualBacking = self.actualDelegatorBacking()
        let maxLoss = self.totalFlowStaked > actualBacking
            ? self.totalFlowStaked - actualBacking
            : 0.0
        assert(
            amount <= maxLoss,
            message: "Loss \(amount) exceeds verifiable shortfall \(maxLoss)"
        )

        self.totalFlowStaked = self.totalFlowStaked - amount
        emit LossRealized(amount: amount, totalFlowStaked: self.totalFlowStaked)

        /// If the loss wipes out all backing while sFLOW supply remains, the pool is
        /// insolvent and `flowPerSFlowScaled` would panic. Do not push a stale rate
        /// to EVM in that edge case; admin recapitalization is required before any
        /// new operation can succeed.
        if self.totalFlowStaked > 0.0 {
            admin.syncRate(rateScaled: self.flowPerSFlowScaled())
        }
    }

    /// Sum of all FLOW currently in protocol delegator buckets (committed + staked +
    /// unstaking + unstaked + rewarded), read directly from the canonical
    /// `FlowIDTableStaking.DelegatorInfo` for each slot. Used to bound `realizeLoss`.
    /// `tokensRequestedToUnstake` is excluded because it is already reflected in
    /// `tokensCommitted` + `tokensStaked`; adding it again double-counts the same FLOW.
    access(self) fun actualDelegatorBacking(): UFix64 {
        var total = 0.0
        let snapshots = LiquidStakingConfig.getSlotSnapshots()
        var i = 0
        while i < snapshots.length {
            let s = snapshots[i]
            let info = FlowIDTableStaking.DelegatorInfo(
                nodeID: s.nodeID,
                delegatorID: s.flowDelegatorId
            )
            total = total
                + info.tokensCommitted
                + info.tokensStaked
                + info.tokensUnstaking
                + info.tokensUnstaked
                + info.tokensRewarded
            i = i + 1
        }
        return total
    }

    access(all) struct FlowReceiptMetadata {
        access(all) let flowAmount: UFix64
        access(all) let unlockEpoch: UInt64

        init(flowAmount: UFix64, unlockEpoch: UInt64) {
            self.flowAmount = flowAmount
            self.unlockEpoch = unlockEpoch
        }
    }

    access(all) resource interface FlowReceiptCollectionPublic {
        access(all) fun getFlowReceiptInfos(): [AnyStruct]
        access(all) fun deposit(receipt: @FlowReceipt)
    }

    access(all) resource FlowReceiptCollection: FlowReceiptCollectionPublic {
        access(self) var receipts: @{UInt64: FlowReceipt}
        access(self) var receiptMetas: {UInt64: FlowReceiptMetadata}

        access(all) fun deposit(receipt: @FlowReceipt) {
            let uuid = receipt.uuid
            assert(
                self.receipts[uuid] == nil,
                message: "FlowReceipt with uuid \(uuid) already in collection"
            )
            let flowAmount = receipt.amount
            let unlockEpoch = receipt.unlockEpoch
            self.receiptMetas[uuid] = FlowReceiptMetadata(
                flowAmount: flowAmount,
                unlockEpoch: unlockEpoch
            )
            self.receipts[uuid] <-! receipt
            emit FlowReceiptDeposited(
                id: uuid,
                flowAmount: flowAmount,
                unlockEpoch: unlockEpoch,
                owner: self.owner?.address
            )
        }

        access(FungibleToken.Withdraw) fun withdraw(uuid: UInt64): @FlowReceipt {
            let receipt <- self.receipts.remove(key: uuid)
                ?? panic("No FlowReceipt with uuid \(uuid)")
            let _ = self.receiptMetas.remove(key: uuid)
            emit FlowReceiptWithdrawn(
                id: uuid,
                flowAmount: receipt.amount,
                unlockEpoch: receipt.unlockEpoch,
                owner: self.owner?.address
            )
            return <- receipt
        }

        /// Each entry: `{ "uuid", "flowAmount", "unlockEpoch" }` (matches **`FlowReceipt`** fields).
        /// Not `view`: building the result uses `append`, which mutates a local array in place.
        access(all) fun getFlowReceiptInfos(): [AnyStruct] {
            var infos: [AnyStruct] = []
            let keys = self.receiptMetas.keys
            var index = 0
            while index < keys.length {
                let uuid = keys[index]
                let meta = self.receiptMetas[uuid]!
                infos.append({
                    "uuid": uuid,
                    "flowAmount": meta.flowAmount,
                    "unlockEpoch": meta.unlockEpoch
                })
                index = index + 1
            }
            return infos
        }

        init() {
            self.receipts <- {}
            self.receiptMetas = {}
        }
    }

    access(all) fun createEmptyFlowReceiptCollection(): @FlowReceiptCollection {
        return <-create FlowReceiptCollection()
    }

    /// Only router can call this contract. Making sure it is synchronously updates both cadence and evm
    access(account) fun compoundRewards() {
        pre {
            FlowIDTableStaking.stakingEnabled() == true: "Not in the Flow chain staking period"
            sFlowToken.totalSupply > 0.0:
                "Total sFlow supply \(sFlowToken.totalSupply) must be > 0 to compound rewards"
        }

        let result = LiquidStakingConfig.compoundDelegatorRewards()
        if result.rewardAmount <= 0.0 { return }

        self.totalFlowStaked = self.totalFlowStaked + result.restakedAmount

        emit RewardsCompounded(rewardAmount: result.rewardAmount, feeAmount: result.feeAmount)
    }

    access(all) fun getDelegatorInfo(): FlowIDTableStaking.DelegatorInfo {
        return LiquidStakingConfig.getDepositTargetInfo()
    }

    /// Canonical FLOW-per-sFLOW rate at `EVMRoute.ratioScaleFactor` (1e18). Use this for
    /// EVM `syncRate` and any protocol path. Token vaults stay `UFix64`; the *rate* does not.
    access(all) view fun flowPerSFlowScaled(): UInt256 {
        if self.totalFlowStaked == 0.0 {
            assert(
                sFlowToken.totalSupply == 0.0,
                message: "FLOW backing is zero while sFLOW supply remains; pool is insolvent"
            )
            return EVMRoute.ratioScaleFactor
        }
        let backingScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(self.totalFlowStaked)
        let supplyScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowToken.totalSupply)
        return backingScaled * EVMRoute.ratioScaleFactor / supplyScaled
    }

    access(all) view fun sFlowPerFlowScaled(): UInt256 {
        if self.totalFlowStaked == 0.0 {
            assert(
                sFlowToken.totalSupply == 0.0,
                message: "FLOW backing is zero while sFLOW supply remains; pool is insolvent"
            )
            return EVMRoute.ratioScaleFactor
        }
        let backingScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(self.totalFlowStaked)
        let supplyScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowToken.totalSupply)
        return supplyScaled * EVMRoute.ratioScaleFactor / backingScaled
    }

    /// Display helper. Not used by rate sync. Panics if the scaled rate cannot fit in `UFix64`.
    access(all) view fun flowPerSFlow(): UFix64 {
        return EVMRoute.ratioScaled1e18ToUFix64(self.flowPerSFlowScaled())
    }

    access(all) view fun sFlowPerFlow(): UFix64 {
        return EVMRoute.ratioScaled1e18ToUFix64(self.sFlowPerFlowScaled())
    }

    access(all) view fun calcSFlowFromFlow(flowAmount: UFix64): UFix64 {
        if self.totalFlowStaked <= 0.0 {
            assert(
                sFlowToken.totalSupply <= 0.0,
                message: "Cannot mint sFLOW while FLOW backing is zero"
            )
            return flowAmount
        }
        let backingScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(self.totalFlowStaked)
        let supplyScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowToken.totalSupply)
        let amountScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(flowAmount)
        return EVMRoute.scaledUInt256ToTokenUFix64(
            supplyScaled * amountScaled / backingScaled
        )
    }

    access(all) view fun calcFlowFromSFlow(sFlowAmount: UFix64): UFix64 {
        pre {
            sFlowToken.totalSupply > 0.0:
                "sFlow supply \(sFlowToken.totalSupply) must be > 0"
            self.totalFlowStaked > 0.0:
                "FLOW backing \(self.totalFlowStaked) must be > 0"
        }
        let backingScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(self.totalFlowStaked)
        let supplyScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowToken.totalSupply)
        let amountScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowAmount)
        return EVMRoute.scaledUInt256ToTokenUFix64(
            backingScaled * amountScaled / supplyScaled
        )
    }

    init() {
        self.FlowReceiptCollectionPath = /storage/liquid_staking_flow_receipt_collection
        self.FlowReceiptCollectionPublicPath = /public/liquid_staking_flow_receipt_collection
        self.totalFlowStaked = 0.0
        self.totalFlowReceiptsOutstanding = 0.0
        self.protocolOwnedSFlowFloor = 1.0
        self.protocolOwnedSFlow <- sFlowToken.createEmptyVault(vaultType: Type<@sFlowToken.Vault>())
        let pool <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        self.account.storage.save(<-pool, to: LiquidStakingConfig.WithdrawPoolStoragePath)
    }
}
