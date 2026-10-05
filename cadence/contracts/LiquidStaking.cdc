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
    access(all) var totalFlowReceiptsOutstanding: UFix64

    access(all) var outstandingLossFactor: UFix64

    /// FLOW that a receipt settlement (`withdrawStuckReceipt` /
    /// `settleNativeStuckReceipt`) could not pay out, pending admin classification as
    /// either recoverable (`reconcileRecoveredShortfall`) or a permanent loss
    /// (`writeOffShortfall`). Unlike the prior behavior of unconditionally re-adding the
    /// unpaid remainder to `totalFlowStaked`, this counter is deliberately excluded from
    /// `totalFlowStaked` so sFLOW backing is never overstated by an unverified remainder --
    /// a genuine permanent loss must not silently inflate the exchange rate's backing.
    access(all) var unclassifiedShortfall: UFix64

    /// Permanently locked protocol-owned sFLOW. Seeded once with matching FLOW backing so
    /// `totalSupply` cannot be burned down to a UFix64 dust amount.
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
    access(all) event ShortfallRecorded(receiptId: UInt64, amount: UFix64, unclassifiedShortfall: UFix64)
    access(all) event ShortfallReconciled(amount: UFix64, totalFlowStaked: UFix64, unclassifiedShortfall: UFix64)
    access(all) event ShortfallWrittenOff(amount: UFix64, unclassifiedShortfall: UFix64)

    /// Bearer resource proving the holder is owed `amount` FLOW after `unlockEpoch`.
    /// Destroying this resource outside the protocol `withdraw` / `withdrawStuckReceipt`
    /// paths forfeits the withdrawal credential: the underlying FLOW and the slot's
    /// `pendingClaims` remain in the protocol, but no one can present the receipt to
    /// withdraw them. This is an accepted design limitation, not a recoverable error.
    access(all) resource FlowReceipt {
        access(all) let amount: UFix64
        access(all) let unlockEpoch: UInt64
        access(all) let lossFactorAtCreation: UFix64

        init(amount: UFix64, unlockEpoch: UInt64, lossFactorAtCreation: UFix64) {
            self.amount = amount
            self.unlockEpoch = unlockEpoch
            self.lossFactorAtCreation = lossFactorAtCreation
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

        // actualDelegatorBacking() reflects FLOW reserved for both live
        // sFLOW backing (totalFlowStaked) and outstanding FlowReceipt claims
        // (totalFlowReceiptsOutstanding), so the reconciliation guard must compare
        // against their combined basis, not totalFlowStaked alone.
        let basis = self.totalFlowStaked + self.totalFlowReceiptsOutstanding
        assert(
            basis <= self.actualDelegatorBacking(),
            message: "Unstaking is blocked until reconciled: combined basis \(basis) exceeds actual backing \(self.actualDelegatorBacking())"
        )

        let sFlowAmount = from.balance
        let flowAmount = self.calcFlowFromSFlow(sFlowAmount: sFlowAmount)
        assert(
            flowAmount >= LiquidStakingConfig.minOperationAmount,
            message: "Unstake FLOW amount \(flowAmount) must be >= min \(LiquidStakingConfig.minOperationAmount)"
        )

        sFlowToken.burnTokens(from: <-from)

        let allocation = LiquidStakingConfig.requestWithdrawFromStaked(amount: flowAmount)

        self.totalFlowStaked = self.totalFlowStaked - flowAmount

        let receipt <- create FlowReceipt(
            amount: flowAmount,
            unlockEpoch: allocation.unlockEpoch,
            lossFactorAtCreation: self.outstandingLossFactor
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
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch + LiquidStakingConfig.unstakeUnlockEpochDelay:
                "Unstake not unlocked: epoch \(FlowEpoch.currentEpochCounter) < unlock \(receipt.unlockEpoch) + delay \(LiquidStakingConfig.unstakeUnlockEpochDelay)"
        }

        let effective = self.effectiveReceiptAmount(receipt: &receipt as &FlowReceipt)
        let flowVault <- LiquidStakingConfig.withdrawFromUnstakedPartial(
            receiptUuid: receipt.uuid,
            claimAmount: receipt.amount,
            maxWithdraw: effective
        )
        assert(
            flowVault.balance == effective,
            message: "Insufficient unstaked FLOW for effective receipt amount \(effective)"
        )

        self.releaseOutstanding(amount: effective)
        emit UnstakeFulfilled(id: receipt.uuid, flowAmount: effective)
        destroy receipt

        return <- flowVault
    }

    access(account) fun withdrawStuckReceipt(receipt: @FlowReceipt): @FlowToken.Vault {
        pre {
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch:
                "Base unstake unlock epoch not reached: epoch \(FlowEpoch.currentEpochCounter) < \(receipt.unlockEpoch)"
        }

        return <- self.settleReceiptInternal(receipt: <-receipt)
    }

    access(all) fun settleNativeStuckReceipt(receipt: @FlowReceipt): @FlowToken.Vault {
        pre {
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch + LiquidStakingConfig.unstakeUnlockEpochDelay:
                "Unstake not unlocked: epoch \(FlowEpoch.currentEpochCounter) < unlock \(receipt.unlockEpoch) + delay \(LiquidStakingConfig.unstakeUnlockEpochDelay)"
        }

        return <- self.settleReceiptInternal(receipt: <-receipt)
    }

    /// The unpaid remainder (`effective - returned`) is recorded in
    /// `unclassifiedShortfall` rather than unconditionally re-added to `totalFlowStaked`.
    /// Whether that remainder is actually still recoverable (e.g. still in flight, delayed
    /// but not lost) or a permanent slashing loss is a judgment call this settlement path
    /// cannot make on its own -- it only observes that the delegator bucket came up short.
    /// The admin resolves the classification afterward via `reconcileRecoveredShortfall`
    /// (if verified recoverable) or `writeOffShortfall` (if a confirmed permanent loss),
    /// which is tracked independently of any specific receipt.
    access(self) fun settleReceiptInternal(receipt: @FlowReceipt): @FlowToken.Vault {
        let effective = self.effectiveReceiptAmount(receipt: &receipt as &FlowReceipt)
        let flowVault <- LiquidStakingConfig.withdrawFromUnstakedPartial(
            receiptUuid: receipt.uuid,
            claimAmount: receipt.amount,
            maxWithdraw: effective
        )
        let returned = flowVault.balance
        let shortfall = effective - returned

        if shortfall > 0.0 {
            self.unclassifiedShortfall = self.unclassifiedShortfall + shortfall
            emit ShortfallRecorded(
                receiptId: receipt.uuid,
                amount: shortfall,
                unclassifiedShortfall: self.unclassifiedShortfall
            )
        }
        self.releaseOutstanding(amount: effective)
        emit UnstakeFulfilled(id: receipt.uuid, flowAmount: returned)
        destroy receipt

        return <- flowVault
    }

    /// Admin confirms that some or all of `unclassifiedShortfall` is still
    /// recoverable (e.g. FLOW that was merely delayed, not permanently lost) and restores
    /// it to `totalFlowStaked`. Bounded by the verified shortfall between the resulting
    /// combined basis and `actualDelegatorBacking()` so this can never push recorded
    /// backing above what is actually present -- the same guard `realizeLoss()` uses,
    /// mirrored here to prevent recreating the original phantom-backing bug.
    access(all) fun reconcileRecoveredShortfall(amount: UFix64, admin: &LiquidStakingConfig.Admin) {
        pre {
            amount > 0.0: "Reconciled amount must be positive"
            amount <= self.unclassifiedShortfall:
                "Reconciled amount \(amount) exceeds unclassifiedShortfall \(self.unclassifiedShortfall)"
        }

        let actualBacking = self.actualDelegatorBacking()
        let basisAfter = self.totalFlowStaked + amount + self.totalFlowReceiptsOutstanding
        assert(
            basisAfter <= actualBacking,
            message: "Reconciled amount \(amount) would push combined basis \(basisAfter) above actual backing \(actualBacking)"
        )

        self.unclassifiedShortfall = self.unclassifiedShortfall - amount
        self.totalFlowStaked = self.totalFlowStaked + amount
        emit ShortfallReconciled(
            amount: amount,
            totalFlowStaked: self.totalFlowStaked,
            unclassifiedShortfall: self.unclassifiedShortfall
        )
    }

    /// Admin confirms that some or all of `unclassifiedShortfall` is a permanent,
    /// unrecoverable loss. No backing adjustment is needed here: the amount was never added
    /// to `totalFlowStaked` in the first place, so simply clearing the counter is sufficient
    /// to close out the claim without ever having inflated the exchange-rate backing.
    access(all) fun writeOffShortfall(amount: UFix64, admin: &LiquidStakingConfig.Admin) {
        pre {
            amount > 0.0: "Write-off amount must be positive"
            amount <= self.unclassifiedShortfall:
                "Write-off amount \(amount) exceeds unclassifiedShortfall \(self.unclassifiedShortfall)"
        }

        self.unclassifiedShortfall = self.unclassifiedShortfall - amount
        emit ShortfallWrittenOff(amount: amount, unclassifiedShortfall: self.unclassifiedShortfall)
    }

    /// `totalFlowStaked` alone understates the FLOW the protocol has promised,
    /// because it excludes `totalFlowReceiptsOutstanding` (FLOW already reserved for
    /// unmatured/unsettled `FlowReceipt`s). `actualDelegatorBacking()` *does* include that
    /// reserved FLOW, so comparing it against `totalFlowStaked` alone mismatches bases and
    /// can understate a genuine shortfall. We measure and allocate the loss against the
    /// combined basis `B + Q` (sFLOW backing + outstanding receipt claims) and scale both
    /// components down by the same ratio, so neither sFLOW holders nor pending receipt
    /// holders are shielded from (or over-exposed to) a confirmed loss relative to the other.
    access(all) fun realizeLoss(amount: UFix64, admin: &LiquidStakingConfig.Admin) {
        pre {
            amount > 0.0: "Loss amount must be positive"
        }

        let basis = self.totalFlowStaked + self.totalFlowReceiptsOutstanding
        assert(basis > 0.0, message: "No FLOW basis to realize a loss against")

        let actualBacking = self.actualDelegatorBacking()
        let maxLoss = basis > actualBacking
            ? basis - actualBacking
            : 0.0
        assert(
            amount <= maxLoss,
            message: "Loss \(amount) exceeds verifiable shortfall \(maxLoss)"
        )

        let lossRatio = amount / basis
        self.outstandingLossFactor = self.outstandingLossFactor + (1.0 - self.outstandingLossFactor) * lossRatio

        // Derive the post-loss combined basis by exact subtraction (no extra rounding beyond
        // the already-UFix64-grid-aligned inputs), then split it between the two components so
        // their sum always matches `newBasis` exactly. Multiplying each component by
        // `(1.0 - lossRatio)` independently (as the naive pro-rata formula suggests) can leave a
        // small residual dust between `totalFlowStaked + totalFlowReceiptsOutstanding` and
        // `actualDelegatorBacking()` after realizing the full verifiable shortfall, which would
        // then permanently block the `unstake()` reconciliation guard by that dust amount.
        let newBasis = basis - amount
        var receiptsAfter = self.totalFlowReceiptsOutstanding * (1.0 - lossRatio)
        if receiptsAfter > newBasis {
            receiptsAfter = newBasis
        }
        self.totalFlowReceiptsOutstanding = receiptsAfter
        self.totalFlowStaked = newBasis - receiptsAfter

        emit LossRealized(amount: amount, totalFlowStaked: self.totalFlowStaked)
    }

    /// Net-reward rounding must match `LiquidStakingConfig.compoundAll()`'s basis
    /// (`fee = gross * feePercent; net = gross - fee`) exactly, rather than the
    /// mathematically-equivalent-in-reals-but-UFix64-truncation-divergent `gross * (1 -
    /// feePercent)`. The two formulas can disagree by up to one UFix64 ULP (1e-8 FLOW) per
    /// slot, which otherwise feeds a rounding mismatch directly into the `realizeLoss()` /
    /// `maxRealizableLoss()` shortfall measurement.
    access(self) fun actualDelegatorBacking(): UFix64 {
        var total = 0.0
        let snapshots = LiquidStakingConfig.getSlotSnapshots()
        let feePercent = LiquidStakingConfig.protocolFeePercent
        var i = 0
        while i < snapshots.length {
            let s = snapshots[i]
            let info = FlowIDTableStaking.DelegatorInfo(
                nodeID: s.nodeID,
                delegatorID: s.flowDelegatorId
            )
            let grossRewarded = info.tokensRewarded
            let feeAmount = grossRewarded * feePercent
            let netRewarded = grossRewarded - feeAmount
            total = total
                + info.tokensCommitted
                + info.tokensStaked
                + info.tokensUnstaking
                + info.tokensUnstaked
                + netRewarded
            i = i + 1
        }
        return total
    }

    /// Measured on the same combined basis (`totalFlowStaked +
    /// totalFlowReceiptsOutstanding`) as `realizeLoss()` and `actualDelegatorBacking()`.
    access(all) fun maxRealizableLoss(): UFix64 {
        let basis = self.totalFlowStaked + self.totalFlowReceiptsOutstanding
        let actualBacking = self.actualDelegatorBacking()
        return basis > actualBacking
            ? basis - actualBacking
            : 0.0
    }

    access(self) view fun effectiveReceiptAmount(receipt: &FlowReceipt): UFix64 {
        if self.outstandingLossFactor >= 1.0 {
            return 0.0
        }
        let oneMinusGlobal = 1.0 - self.outstandingLossFactor
        let oneMinusCreation = 1.0 - receipt.lossFactorAtCreation
        if oneMinusCreation == 0.0 {
            return 0.0
        }
        return receipt.amount * oneMinusGlobal / oneMinusCreation
    }

    access(self) fun releaseOutstanding(amount: UFix64) {
        if amount > self.totalFlowReceiptsOutstanding {
            self.totalFlowReceiptsOutstanding = 0.0
        } else {
            self.totalFlowReceiptsOutstanding = self.totalFlowReceiptsOutstanding - amount
        }
    }

    access(all) struct FlowReceiptMetadata {
        access(all) let flowAmount: UFix64
        access(all) let unlockEpoch: UInt64
        access(all) let lossFactorAtCreation: UFix64

        init(flowAmount: UFix64, unlockEpoch: UInt64, lossFactorAtCreation: UFix64) {
            self.flowAmount = flowAmount
            self.unlockEpoch = unlockEpoch
            self.lossFactorAtCreation = lossFactorAtCreation
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
            let lossFactorAtCreation = receipt.lossFactorAtCreation
            self.receiptMetas[uuid] = FlowReceiptMetadata(
                flowAmount: flowAmount,
                unlockEpoch: unlockEpoch,
                lossFactorAtCreation: lossFactorAtCreation
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
                    "unlockEpoch": meta.unlockEpoch,
                    "lossFactorAtCreation": meta.lossFactorAtCreation
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
    /// EVM `syncBacking` and any protocol path. Token vaults stay `UFix64`; the *rate* does not.
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
        self.outstandingLossFactor = 0.0
        self.unclassifiedShortfall = 0.0
        self.protocolOwnedSFlowFloor = 1.0
        self.protocolOwnedSFlow <- sFlowToken.createEmptyVault(vaultType: Type<@sFlowToken.Vault>())
        let pool <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        self.account.storage.save(<-pool, to: LiquidStakingConfig.WithdrawPoolStoragePath)
    }
}
