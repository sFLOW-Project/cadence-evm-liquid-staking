import "FlowToken"
import "FungibleToken"
import "FlowIDTableStaking"
import "FlowEpoch"
import "EVM"
import "EVMRoute"

/// Governance parameters, **`Admin`**, and the protocol **delegator manager**
///
/// **Config / manager owns:** NodeDelegator custody (`DelegatorSet`), node
/// lifecycle (register / drain / retire), and `access(account)` FLOW primitives
/// that move tokens in Flow staking buckets (deposit, request unstake with
/// exiting-bucket allocation, withdraw unstaked, compound).
///
/// **`LiquidStaking` owns:** user-facing stake / unstake / withdraw, sFLOW
/// mint-burn, `FlowReceipt`s, and `totalFlowStaked` exchange-rate accounting.
/// It calls the manager primitives below; it never borrows a `NodeDelegator`.
///
/// Deploy on the **same account** as **`LiquidStaking`**.
access(all) contract LiquidStakingConfig {

    access(all) var protocolFeeReceiver: Address
    access(all) let ProtocolFeeReceiverPublicPath: PublicPath

    access(all) let protocolFeeTimelockDuration: UInt64
    access(all) var protocolFeeTimelockExpiration: UInt64
    access(all) var protocolFeePercentQueued: UFix64?
    access(all) var protocolFeePercent: UFix64

    access(all) var isStakingPaused: Bool
    access(all) var minOperationAmount: UFix64

    access(all) var unstakeUnlockEpochDelay: UInt64

    access(all) let AdminStoragePath: StoragePath
    access(all) let DelegatorStoragePath: StoragePath
    access(all) let WithdrawPoolStoragePath: StoragePath

    access(all) let slotStatusActive: UInt8
    access(all) let slotStatusDraining: UInt8

    access(all) event ProtocolFeeUpdateQueued(newFee: UFix64)
    access(all) event ProtocolFeeUpdated(oldFee: UFix64, newFee: UFix64)
    access(all) event ProtocolFeeReceiverUpdated(oldReceiver: Address, newReceiver: Address)
    access(all) event StakingPauseUpdated(paused: Bool)
    access(all) event MinStakeUpdated(oldMin: UFix64, newMin: UFix64)
    access(all) event UnstakeUnlockEpochDelayUpdated(oldDelayEpochs: UInt64, newDelayEpochs: UInt64)
    access(all) event DelegatorSlotAdded(slotId: UInt64, nodeID: String, flowDelegatorId: UInt32)
    access(all) event DelegatorSlotDraining(slotId: UInt64)
    access(all) event DepositTargetUpdated(slotId: UInt64)
    access(all) event DelegatorSlotRetired(slotId: UInt64)
    access(all) event UnstakeAllocated(
        receiptUuid: UInt64,
        flowAmount: UFix64,
        unlockEpoch: UInt64,
        legCount: Int
    )
    access(all) event UnstakeClaimWithdrawn(receiptUuid: UInt64, flowAmount: UFix64)

    /// Pair used to order exiting slots by earliest unlock epoch (SFL-06).
    access(all) struct SlotEpoch {
        access(all) let slotId: UInt64
        access(all) let epoch: UInt64
        init(slotId: UInt64, epoch: UInt64) {
            self.slotId = slotId
            self.epoch = epoch
        }
    }

    /// One claim against a single slot for a receipt.
    access(all) struct ClaimLeg {
        access(all) let slotId: UInt64
        access(all) let amount: UFix64
        access(all) let unlockEpoch: UInt64

        init(slotId: UInt64, amount: UFix64, unlockEpoch: UInt64) {
            self.slotId = slotId
            self.amount = amount
            self.unlockEpoch = unlockEpoch
        }
    }

    access(all) struct AllocationResult {
        access(all) let ticketId: UInt64
        access(all) let unlockEpoch: UInt64
        access(all) let amount: UFix64

        init(ticketId: UInt64, unlockEpoch: UInt64, amount: UFix64) {
            self.ticketId = ticketId
            self.unlockEpoch = unlockEpoch
            self.amount = amount
        }
    }

    access(all) struct CompoundResult {
        access(all) let rewardAmount: UFix64
        access(all) let feeAmount: UFix64
        access(all) let restakedAmount: UFix64

        init(rewardAmount: UFix64, feeAmount: UFix64, restakedAmount: UFix64) {
            self.rewardAmount = rewardAmount
            self.feeAmount = feeAmount
            self.restakedAmount = restakedAmount
        }
    }

    access(all) struct SlotSnapshot {
        access(all) let slotId: UInt64
        access(all) let nodeID: String
        access(all) let flowDelegatorId: UInt32
        access(all) let status: UInt8
        access(all) let pendingClaims: UFix64
        access(all) let tokensCommitted: UFix64
        access(all) let tokensStaked: UFix64
        access(all) let tokensUnstaking: UFix64
        access(all) let tokensUnstaked: UFix64
        access(all) let tokensRewarded: UFix64
        access(all) let tokensRequestedToUnstake: UFix64

        init(
            slotId: UInt64,
            nodeID: String,
            flowDelegatorId: UInt32,
            status: UInt8,
            pendingClaims: UFix64,
            info: FlowIDTableStaking.DelegatorInfo
        ) {
            self.slotId = slotId
            self.nodeID = nodeID
            self.flowDelegatorId = flowDelegatorId
            self.status = status
            self.pendingClaims = pendingClaims
            self.tokensCommitted = info.tokensCommitted
            self.tokensStaked = info.tokensStaked
            self.tokensUnstaking = info.tokensUnstaking
            self.tokensUnstaked = info.tokensUnstaked
            self.tokensRewarded = info.tokensRewarded
            self.tokensRequestedToUnstake = info.tokensRequestedToUnstake
        }
    }

    access(all) resource DelegatorSlot {
        access(all) let id: UInt64
        access(all) var status: UInt8
        access(all) var pendingClaims: UFix64
        access(contract) let delegator: @FlowIDTableStaking.NodeDelegator

        access(contract) fun borrowDelegator(): auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator {
            return &self.delegator as auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator
        }

        access(contract) fun info(): FlowIDTableStaking.DelegatorInfo {
            return FlowIDTableStaking.DelegatorInfo(
                nodeID: self.delegator.nodeID,
                delegatorID: self.delegator.id
            )
        }

        access(contract) fun setStatus(_ status: UInt8) {
            self.status = status
        }

        access(contract) fun addPendingClaims(_ amount: UFix64) {
            self.pendingClaims = self.pendingClaims + amount
        }

        access(contract) fun reducePendingClaims(_ amount: UFix64) {
            assert(
                self.pendingClaims >= amount,
                message: "DelegatorSlot \(self.id): pendingClaims \(self.pendingClaims) < reduce \(amount)"
            )
            self.pendingClaims = self.pendingClaims - amount
        }

        init(id: UInt64, delegator: @FlowIDTableStaking.NodeDelegator) {
            self.id = id
            self.status = LiquidStakingConfig.slotStatusActive
            self.pendingClaims = 0.0
            self.delegator <- delegator
        }
    }

    /// Owns all protocol NodeDelegators and claim accounting.
    access(all) resource DelegatorSet {
        access(self) var slots: @{UInt64: DelegatorSlot}
        access(self) var depositTarget: UInt64?
        access(self) var nextSlotId: UInt64
        access(self) var nextTicketId: UInt64
        access(self) var totalPendingWithdrawal: UFix64
        access(self) var claimsByReceipt: {UInt64: [ClaimLeg]}
        access(self) var pendingTickets: {UInt64: [ClaimLeg]}

        access(all) view fun getDepositTarget(): UInt64? {
            return self.depositTarget
        }

        access(all) view fun getTotalPendingWithdrawal(): UFix64 {
            return self.totalPendingWithdrawal
        }

        access(all) view fun getSlotIds(): [UInt64] {
            return self.slots.keys
        }

        access(all) fun getSlotSnapshot(slotId: UInt64): SlotSnapshot {
            let slot = self.borrowSlot(slotId)
            let info = slot.info()
            return SlotSnapshot(
                slotId: slot.id,
                nodeID: info.nodeID,
                flowDelegatorId: info.id,
                status: slot.status,
                pendingClaims: slot.pendingClaims,
                info: info
            )
        }

        access(all) fun getAllSlotSnapshots(): [SlotSnapshot] {
            var out: [SlotSnapshot] = []
            let keys = self.slots.keys
            var i = 0
            while i < keys.length {
                out.append(self.getSlotSnapshot(slotId: keys[i]))
                i = i + 1
            }
            return out
        }

        access(all) fun getClaimLegs(receiptUuid: UInt64): [ClaimLeg]? {
            return self.claimsByReceipt[receiptUuid]
        }

        access(contract) fun insertSlot(delegator: @FlowIDTableStaking.NodeDelegator): UInt64 {
            let slotId = self.nextSlotId
            self.nextSlotId = slotId + 1
            let nodeID = delegator.nodeID
            let flowId = delegator.id
            let slot <- create DelegatorSlot(id: slotId, delegator: <-delegator)
            let prev <- self.slots.insert(key: slotId, <-slot)
            destroy prev
            if self.depositTarget == nil {
                self.depositTarget = slotId
                emit DepositTargetUpdated(slotId: slotId)
            }
            emit DelegatorSlotAdded(slotId: slotId, nodeID: nodeID, flowDelegatorId: flowId)
            return slotId
        }

        access(contract) fun markDraining(slotId: UInt64) {
            let slot = self.borrowSlot(slotId)
            assert(
                slot.status == LiquidStakingConfig.slotStatusActive,
                message: "Slot \(slotId) is not Active"
            )

            slot.setStatus(LiquidStakingConfig.slotStatusDraining)

            // Move deposit target to another active slot so staking keeps working.
            if self.depositTarget == slotId {
                let activeIds = self.slotIdsWithStatus(LiquidStakingConfig.slotStatusActive)
                if activeIds.length > 0 {
                    self.depositTarget = activeIds[0]
                    emit DepositTargetUpdated(slotId: activeIds[0])
                } else {
                    self.depositTarget = nil
                }
            }
            emit DelegatorSlotDraining(slotId: slotId)
        }

        access(contract) fun setDepositTarget(slotId: UInt64) {
            let slot = self.borrowSlot(slotId)
            assert(
                slot.status == LiquidStakingConfig.slotStatusActive,
                message: "Deposit target slot \(slotId) must be Active"
            )
            self.depositTarget = slotId
            emit DepositTargetUpdated(slotId: slotId)
        }

        access(contract) fun retireSlot(slotId: UInt64) {
            let slot = self.borrowSlot(slotId)
            assert(
                slot.status == LiquidStakingConfig.slotStatusDraining,
                message: "Slot \(slotId) must be Draining before retirement"
            )
            assert(
                slot.pendingClaims == 0.0,
                message: "Cannot retire slot \(slotId) with pendingClaims \(slot.pendingClaims)"
            )
            let info = slot.info()
            let residual =
                info.tokensCommitted + info.tokensStaked + info.tokensUnstaking
                + info.tokensUnstaked + info.tokensRewarded + info.tokensRequestedToUnstake
            assert(
                residual == 0.0,
                message: "Cannot retire slot \(slotId) with residual FLOW \(residual)"
            )

            // If retiring the current deposit target, move target to another active slot.
            if self.depositTarget == slotId {
                let activeIds = self.slotIdsWithStatus(LiquidStakingConfig.slotStatusActive)
                assert(
                    activeIds.length > 0,
                    message: "Cannot retire deposit target slot \(slotId): no active slot to replace it"
                )
                self.depositTarget = activeIds[0]
                emit DepositTargetUpdated(slotId: activeIds[0])
            }

            let removed <- self.slots.remove(key: slotId)
                ?? panic("Slot \(slotId) missing")
            destroy removed
            emit DelegatorSlotRetired(slotId: slotId)
        }

        access(contract) fun depositToActive(from: @FlowToken.Vault) {
            let targetId = self.depositTarget
                ?? panic("No Active deposit target configured")
            let slot = self.borrowSlot(targetId)
            assert(
                slot.status == LiquidStakingConfig.slotStatusActive,
                message: "Deposit target slot \(targetId) is not Active"
            )
            slot.borrowDelegator().delegateNewTokens(from: <-from)
        }

        /// Reserve FLOW for a redemption. Prefers unallocated exiting buckets, then opens
        /// a new `requestUnstaking` on Active slots only.
        access(contract) fun allocateUnstake(amount: UFix64): AllocationResult {
            pre {
                amount > 0.0: "allocateUnstake amount must be > 0"
            }

            var remaining = amount
            var legs: [ClaimLeg] = []
            var unlockEpoch = FlowEpoch.currentEpochCounter

            let drainingIds = self.slotIdsWithStatus(LiquidStakingConfig.slotStatusDraining)
            let drainPass = self.allocateExitingAcross(slotIds: drainingIds, remaining: remaining)
            remaining = drainPass.remaining
            unlockEpoch = LiquidStakingConfig.maxUInt64(unlockEpoch, drainPass.unlockEpoch)
            legs = LiquidStakingConfig.concatLegs(legs, drainPass.legs)

            let activeIds = self.slotIdsWithStatus(LiquidStakingConfig.slotStatusActive)
            let activeExitPass = self.allocateExitingAcross(slotIds: activeIds, remaining: remaining)
            remaining = activeExitPass.remaining
            unlockEpoch = LiquidStakingConfig.maxUInt64(unlockEpoch, activeExitPass.unlockEpoch)
            legs = LiquidStakingConfig.concatLegs(legs, activeExitPass.legs)

            let requestPass = self.allocateNewRequestsAcross(slotIds: activeIds, remaining: remaining)
            remaining = requestPass.remaining
            unlockEpoch = LiquidStakingConfig.maxUInt64(unlockEpoch, requestPass.unlockEpoch)
            legs = LiquidStakingConfig.concatLegs(legs, requestPass.legs)

            assert(
                remaining == 0.0,
                message: "Insufficient delegator liquidity to allocate unstake of \(amount); short \(remaining)"
            )
            assert(legs.length > 0, message: "allocateUnstake produced no claim legs")
            assert(
                self.sumLegs(legs) == amount,
                message: "Claim legs sum \(self.sumLegs(legs)) != amount \(amount)"
            )

            let ticketId = self.nextTicketId
            self.nextTicketId = ticketId + 1
            self.pendingTickets[ticketId] = legs
            self.totalPendingWithdrawal = self.totalPendingWithdrawal + amount

            return AllocationResult(ticketId: ticketId, unlockEpoch: unlockEpoch, amount: amount)
        }

        access(contract) fun bindClaim(ticketId: UInt64, receiptUuid: UInt64) {
            let legs = self.pendingTickets.remove(key: ticketId)
                ?? panic("Unknown allocation ticket \(ticketId)")
            assert(
                self.claimsByReceipt[receiptUuid] == nil,
                message: "Receipt \(receiptUuid) already has claim legs"
            )
            self.claimsByReceipt[receiptUuid] = legs
            emit UnstakeAllocated(
                receiptUuid: receiptUuid,
                flowAmount: self.sumLegs(legs),
                unlockEpoch: self.maxUnlock(legs),
                legCount: legs.length
            )
        }

        access(contract) fun withdrawClaim(receiptUuid: UInt64, amount: UFix64): @FlowToken.Vault {
            let legs = self.claimsByReceipt.remove(key: receiptUuid)
                ?? panic("No claim legs for receipt \(receiptUuid)")
            let expected = self.sumLegs(legs)
            assert(
                expected == amount,
                message: "Receipt \(receiptUuid) claim \(expected) != withdraw \(amount)"
            )

            var out <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()) as! @FlowToken.Vault
            var i = 0
            while i < legs.length {
                let leg = legs[i]
                let slot = self.borrowSlot(leg.slotId)
                let piece <- slot.borrowDelegator()
                    .withdrawUnstakedTokens(amount: leg.amount) as! @FlowToken.Vault
                slot.reducePendingClaims(leg.amount)
                out.deposit(from: <-piece)
                i = i + 1
            }

            assert(
                self.totalPendingWithdrawal >= amount,
                message: "totalPendingWithdrawal \(self.totalPendingWithdrawal) < \(amount)"
            )
            self.totalPendingWithdrawal = self.totalPendingWithdrawal - amount
            emit UnstakeClaimWithdrawn(receiptUuid: receiptUuid, flowAmount: amount)
            return <-out
        }

        /// Partial withdraw for stuck-receipt recovery. Pulls what is available
        /// from each leg's unstaked bucket; refunds shortfall via reduced claim.
        access(contract) fun withdrawClaimPartial(receiptUuid: UInt64, amount: UFix64): @FlowToken.Vault {
            let legs = self.claimsByReceipt.remove(key: receiptUuid)
                ?? panic("No claim legs for receipt \(receiptUuid)")
            let expected = self.sumLegs(legs)
            assert(
                expected == amount,
                message: "Receipt \(receiptUuid) claim \(expected) != withdraw \(amount)"
            )

            var out <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()) as! @FlowToken.Vault
            var withdrawn = 0.0
            var releasedClaims = 0.0
            var i = 0
            while i < legs.length {
                let leg = legs[i]
                let slot = self.borrowSlot(leg.slotId)
                let info = slot.info()
                var take = leg.amount
                if info.tokensUnstaked < take {
                    take = info.tokensUnstaked
                }
                if take > 0.0 {
                    let piece <- slot.borrowDelegator()
                        .withdrawUnstakedTokens(amount: take) as! @FlowToken.Vault
                    out.deposit(from: <-piece)
                    withdrawn = withdrawn + take
                }
                // Full leg claim is released even on shortfall (matches prior
                // withdrawStuckReceipt destroying the receipt).
                slot.reducePendingClaims(leg.amount)
                releasedClaims = releasedClaims + leg.amount
                i = i + 1
            }

            assert(withdrawn > 0.0, message: "No unstaked FLOW available for stuck receipt \(receiptUuid)")
            assert(
                self.totalPendingWithdrawal >= releasedClaims,
                message: "totalPendingWithdrawal underflow on partial withdraw"
            )
            self.totalPendingWithdrawal = self.totalPendingWithdrawal - releasedClaims
            emit UnstakeClaimWithdrawn(receiptUuid: receiptUuid, flowAmount: withdrawn)
            return <-out
        }

        access(contract) fun compoundAll(
            protocolFeePercent: UFix64,
            feeReceiver: Address,
            feeReceiverPath: PublicPath
        ): CompoundResult {
            var totalReward = 0.0
            var totalFee = 0.0
            var totalRestaked = 0.0

            let keys = self.slots.keys
            var i = 0
            while i < keys.length {
                let slot = self.borrowSlot(keys[i])
                let info = slot.info()
                let rewardAmount = info.tokensRewarded
                if rewardAmount > 0.0 {
                    let feeAmount = rewardAmount * protocolFeePercent
                    let restakeAmount = rewardAmount - feeAmount
                    totalReward = totalReward + rewardAmount
                    totalFee = totalFee + feeAmount
                    totalRestaked = totalRestaked + restakeAmount

                    if feeAmount > 0.0 {
                        let feeVault <- slot.borrowDelegator().withdrawRewardedTokens(amount: feeAmount)
                        let treasury = getAccount(feeReceiver)
                            .capabilities
                            .borrow<&{FungibleToken.Receiver}>(feeReceiverPath)
                            ?? panic("Protocol fee receiver not found")
                        treasury.deposit(from: <-feeVault)
                    }

                    if restakeAmount > 0.0 {
                        if slot.status == LiquidStakingConfig.slotStatusActive {
                            slot.borrowDelegator().delegateRewardedTokens(amount: restakeAmount)
                        } else {
                            let restakeVault <- slot.borrowDelegator()
                                .withdrawRewardedTokens(amount: restakeAmount) as! @FlowToken.Vault
                            self.depositToActive(from: <-restakeVault)
                        }
                    }
                }
                i = i + 1
            }

            return CompoundResult(
                rewardAmount: totalReward,
                feeAmount: totalFee,
                restakedAmount: totalRestaked
            )
        }

        /// Earliest unlock epoch a slot can satisfy a new exiting claim, accounting for
        /// existing pendingClaims. Returns UInt64.max if no exiting capacity remains.
        access(self) fun earliestExitingUnlockEpoch(slot: &DelegatorSlot): UInt64 {
            let info = slot.info()
            var unstaked = info.tokensUnstaked
            var unstaking = info.tokensUnstaking
            var requested = info.tokensRequestedToUnstake
            var reserved = slot.pendingClaims

            if reserved > 0.0 {
                let u = reserved < unstaked ? reserved : unstaked
                unstaked = unstaked - u
                reserved = reserved - u
            }
            if reserved > 0.0 {
                let u = reserved < unstaking ? reserved : unstaking
                unstaking = unstaking - u
                reserved = reserved - u
            }
            if reserved > 0.0 {
                let u = reserved < requested ? reserved : requested
                requested = requested - u
                reserved = reserved - u
            }

            let current = FlowEpoch.currentEpochCounter
            if unstaked > 0.0 { return current }
            if unstaking > 0.0 { return current + 1 }
            if requested > 0.0 { return current + 2 }
            return UInt64.max
        }

        /// Sort slot IDs by earliest exiting unlock epoch, using slot ID as tie-breaker.
        access(self) fun sortSlotIdsByExitingEpoch(slotIds: [UInt64]): [UInt64] {
            var pairs: [SlotEpoch] = []
            var i = 0
            while i < slotIds.length {
                let slot = self.borrowSlot(slotIds[i])
                pairs.append(SlotEpoch(
                    slotId: slot.id,
                    epoch: self.earliestExitingUnlockEpoch(slot: slot)
                ))
                i = i + 1
            }

            // Bubble sort: earliest epoch first, slot ID as deterministic tie-breaker.
            i = 0
            while i < pairs.length {
                var j = i + 1
                while j < pairs.length {
                    let pi = pairs[i]
                    let pj = pairs[j]
                    if pj.epoch < pi.epoch || (pj.epoch == pi.epoch && pj.slotId < pi.slotId) {
                        pairs[i] = pj
                        pairs[j] = pi
                    }
                    j = j + 1
                }
                i = i + 1
            }

            var sorted: [UInt64] = []
            var k = 0
            while k < pairs.length {
                sorted.append(pairs[k].slotId)
                k = k + 1
            }
            return sorted
        }

        access(self) fun allocateExitingAcross(slotIds: [UInt64], remaining: UFix64): AllocationPass {
            let orderedIds = self.sortSlotIdsByExitingEpoch(slotIds: slotIds)
            var left = remaining
            var legs: [ClaimLeg] = []
            var unlockEpoch = FlowEpoch.currentEpochCounter
            var i = 0
            while i < orderedIds.length && left > 0.0 {
                let slot = self.borrowSlot(orderedIds[i])
                let info = slot.info()
                let taken = LiquidStakingConfig.takeFromExiting(
                    info: info,
                    pendingClaims: slot.pendingClaims,
                    want: left
                )
                if taken.amount > 0.0 {
                    slot.addPendingClaims(taken.amount)
                    legs.append(ClaimLeg(
                        slotId: slot.id,
                        amount: taken.amount,
                        unlockEpoch: taken.unlockEpoch
                    ))
                    unlockEpoch = LiquidStakingConfig.maxUInt64(unlockEpoch, taken.unlockEpoch)
                    left = left - taken.amount
                }
                i = i + 1
            }
            return AllocationPass(remaining: left, unlockEpoch: unlockEpoch, legs: legs)
        }

        access(self) fun allocateNewRequestsAcross(slotIds: [UInt64], remaining: UFix64): AllocationPass {
            var left = remaining
            var legs: [ClaimLeg] = []
            let requestUnlock = FlowEpoch.currentEpochCounter + 2
            var unlockEpoch = FlowEpoch.currentEpochCounter
            var i = 0
            while i < slotIds.length && left > 0.0 {
                let slot = self.borrowSlot(slotIds[i])
                if slot.status != LiquidStakingConfig.slotStatusActive {
                    i = i + 1
                    continue
                }
                let info = slot.info()
                let free = LiquidStakingConfig.freeStakeCapacity(info: info)
                if free > 0.0 {
                    let take = left < free ? left : free
                    slot.borrowDelegator().requestUnstaking(amount: take)
                    slot.addPendingClaims(take)
                    legs.append(ClaimLeg(
                        slotId: slot.id,
                        amount: take,
                        unlockEpoch: requestUnlock
                    ))
                    unlockEpoch = requestUnlock
                    left = left - take
                }
                i = i + 1
            }
            return AllocationPass(remaining: left, unlockEpoch: unlockEpoch, legs: legs)
        }

        access(self) fun slotIdsWithStatus(_ status: UInt8): [UInt64] {
            var out: [UInt64] = []
            let keys = self.slots.keys
            var i = 0
            while i < keys.length {
                let id = keys[i]
                if self.borrowSlot(id).status == status {
                    out.append(id)
                }
                i = i + 1
            }
            return out
        }

        access(self) fun borrowSlot(_ slotId: UInt64): &DelegatorSlot {
            return &self.slots[slotId] as &DelegatorSlot?
                ?? panic("Delegator slot \(slotId) not found")
        }

        access(self) fun sumLegs(_ legs: [ClaimLeg]): UFix64 {
            var total = 0.0
            var i = 0
            while i < legs.length {
                total = total + legs[i].amount
                i = i + 1
            }
            return total
        }

        access(self) fun maxUnlock(_ legs: [ClaimLeg]): UInt64 {
            var m = FlowEpoch.currentEpochCounter
            var i = 0
            while i < legs.length {
                if legs[i].unlockEpoch > m {
                    m = legs[i].unlockEpoch
                }
                i = i + 1
            }
            return m
        }

        init() {
            self.slots <- {}
            self.depositTarget = nil
            self.nextSlotId = 0
            self.nextTicketId = 1
            self.totalPendingWithdrawal = 0.0
            self.claimsByReceipt = {}
            self.pendingTickets = {}
        }
    }

    access(all) struct AllocationPass {
        access(all) let remaining: UFix64
        access(all) let unlockEpoch: UInt64
        access(all) let legs: [ClaimLeg]

        init(remaining: UFix64, unlockEpoch: UInt64, legs: [ClaimLeg]) {
            self.remaining = remaining
            self.unlockEpoch = unlockEpoch
            self.legs = legs
        }
    }

    access(all) struct ExitingTake {
        access(all) let amount: UFix64
        access(all) let unlockEpoch: UInt64

        init(amount: UFix64, unlockEpoch: UInt64) {
            self.amount = amount
            self.unlockEpoch = unlockEpoch
        }
    }

    access(all) view fun maxUInt64(_ a: UInt64, _ b: UInt64): UInt64 {
        return a > b ? a : b
    }

    access(all) fun concatLegs(_ a: [ClaimLeg], _ b: [ClaimLeg]): [ClaimLeg] {
        var out = a
        var i = 0
        while i < b.length {
            out.append(b[i])
            i = i + 1
        }
        return out
    }

    /// Peel prior `pendingClaims` from exiting buckets (unstaked → unstaking →
    /// requested), then take up to `want` from what remains.
    access(all) fun takeFromExiting(
        info: FlowIDTableStaking.DelegatorInfo,
        pendingClaims: UFix64,
        want: UFix64
    ): ExitingTake {
        var unstaked = info.tokensUnstaked
        var unstaking = info.tokensUnstaking
        var requested = info.tokensRequestedToUnstake
        var reserved = pendingClaims

        if reserved > 0.0 {
            let u = reserved < unstaked ? reserved : unstaked
            unstaked = unstaked - u
            reserved = reserved - u
        }
        if reserved > 0.0 {
            let u = reserved < unstaking ? reserved : unstaking
            unstaking = unstaking - u
            reserved = reserved - u
        }
        if reserved > 0.0 {
            let u = reserved < requested ? reserved : requested
            requested = requested - u
            reserved = reserved - u
        }

        var need = want
        var taken = 0.0
        var unlock = FlowEpoch.currentEpochCounter
        let current = FlowEpoch.currentEpochCounter

        if need > 0.0 && unstaked > 0.0 {
            let t = need < unstaked ? need : unstaked
            taken = taken + t
            need = need - t
            unlock = current
        }
        if need > 0.0 && unstaking > 0.0 {
            let t = need < unstaking ? need : unstaking
            taken = taken + t
            need = need - t
            let cand = current + 1
            if cand > unlock { unlock = cand }
        }
        if need > 0.0 && requested > 0.0 {
            let t = need < requested ? need : requested
            taken = taken + t
            need = need - t
            let cand = current + 2
            if cand > unlock { unlock = cand }
        }

        return ExitingTake(amount: taken, unlockEpoch: unlock)
    }

    access(all) view fun freeStakeCapacity(info: FlowIDTableStaking.DelegatorInfo): UFix64 {
        let avail = info.tokensCommitted + info.tokensStaked
        if avail <= info.tokensRequestedToUnstake {
            return 0.0
        }
        return avail - info.tokensRequestedToUnstake
    }

    access(self) fun borrowSet(): &DelegatorSet {
        return self.account.storage
            .borrow<&DelegatorSet>(from: self.DelegatorStoragePath)
            ?? panic("DelegatorSet not configured at DelegatorStoragePath")
    }

    access(self) fun borrowOrCreateSet(): &DelegatorSet {
        if self.account.storage.borrow<&DelegatorSet>(from: self.DelegatorStoragePath) == nil {
            self.account.storage.save(<-create DelegatorSet(), to: self.DelegatorStoragePath)
        }
        return self.borrowSet()
    }

    // ---- access(account) surface for LiquidStaking ----

    /// Stake newly committed FLOW onto the Active deposit-target delegator.
    /// Called by `LiquidStaking.stake`.
    access(account) fun depositToCommitted(from: @FlowToken.Vault) {
        self.borrowSet().depositToActive(from: <-from)
    }

    /// Reserve / request FLOW for a redemption (prefer unallocated
    /// exiting buckets, then `requestUnstaking` on Active slots).
    /// Called by `LiquidStaking.unstake`. Caller must `bindWithdrawClaim` with
    /// the new `FlowReceipt.uuid` in the same transaction.
    access(account) fun requestWithdrawFromStaked(amount: UFix64): AllocationResult {
        return self.borrowSet().allocateUnstake(amount: amount)
    }

    /// Attach an allocation ticket to a `FlowReceipt` uuid.
    access(account) fun bindWithdrawClaim(ticketId: UInt64, receiptUuid: UInt64) {
        self.borrowSet().bindClaim(ticketId: ticketId, receiptUuid: receiptUuid)
    }

    /// Settle a matured receipt from the slots that hold its claim legs.
    /// Called by `LiquidStaking.withdraw`.
    access(account) fun withdrawFromUnstaked(receiptUuid: UInt64, amount: UFix64): @FlowToken.Vault {
        return <-self.borrowSet().withdrawClaim(receiptUuid: receiptUuid, amount: amount)
    }

    /// Partial settle for stuck EVM receipts (`LiquidStaking.withdrawStuckReceipt`).
    access(account) fun withdrawFromUnstakedPartial(receiptUuid: UInt64, amount: UFix64): @FlowToken.Vault {
        return <-self.borrowSet().withdrawClaimPartial(receiptUuid: receiptUuid, amount: amount)
    }

    /// Harvest rewards across all slots; restake onto Active (or deposit target
    /// if the rewarding slot is Draining).
    access(account) fun compoundDelegatorRewards(): CompoundResult {
        return self.borrowSet().compoundAll(
            protocolFeePercent: self.protocolFeePercent,
            feeReceiver: self.protocolFeeReceiver,
            feeReceiverPath: self.ProtocolFeeReceiverPublicPath
        )
    }

    access(all) fun getDepositTargetSlotId(): UInt64? {
        if let set = self.account.storage.borrow<&DelegatorSet>(from: self.DelegatorStoragePath) {
            return set.getDepositTarget()
        }
        return nil
    }

    access(all) fun getTotalPendingWithdrawal(): UFix64 {
        if let set = self.account.storage.borrow<&DelegatorSet>(from: self.DelegatorStoragePath) {
            return set.getTotalPendingWithdrawal()
        }
        return 0.0
    }

    access(all) fun getSlotSnapshots(): [SlotSnapshot] {
        if let set = self.account.storage.borrow<&DelegatorSet>(from: self.DelegatorStoragePath) {
            return set.getAllSlotSnapshots()
        }
        return []
    }

    access(all) fun getClaimLegs(receiptUuid: UInt64): [ClaimLeg]? {
        if let set = self.account.storage.borrow<&DelegatorSet>(from: self.DelegatorStoragePath) {
            return set.getClaimLegs(receiptUuid: receiptUuid)
        }
        return nil
    }

    access(all) fun getDepositTargetInfo(): FlowIDTableStaking.DelegatorInfo {
        let set = self.borrowSet()
        let target = set.getDepositTarget()
            ?? panic("No deposit target")
        let snap = set.getSlotSnapshot(slotId: target)
        return FlowIDTableStaking.DelegatorInfo(nodeID: snap.nodeID, delegatorID: snap.flowDelegatorId)
    }

    access(all) resource Admin {

        access(self) let coa: @EVM.CadenceOwnedAccount
        access(self) let vault: EVM.EVMAddress

        access(self) fun borrowCoa(): auth(EVM.Call) &EVM.CadenceOwnedAccount {
            return (&self.coa)
        }

        init(coa: @EVM.CadenceOwnedAccount, vault: EVM.EVMAddress) {
            self.coa <- coa
            self.vault = vault
            self.assertEvmSettingsMatchCadence()
        }

        access(self) fun assertEvmSettingsMatchCadence() {
            let cfg = EVMRoute.readVaultConfig(coa: self.borrowCoa(), vault: self.vault)
            let expectedMin = EVMRoute.tokenUFix64ToScaledUInt256(LiquidStakingConfig.minOperationAmount)
            assert(
                cfg.minRequestAmount == expectedMin,
                message: "LSPVault minRequestAmount \(cfg.minRequestAmount) != Cadence minOperationAmount scaled \(expectedMin)"
            )
            assert(
                cfg.isStakingPaused == LiquidStakingConfig.isStakingPaused,
                message: "LSPVault isStakingPaused does not match Cadence isStakingPaused"
            )
        }

        access(all) fun registerDelegator(nodeID: String, from: @FlowToken.Vault) {
            let delegator <- FlowIDTableStaking.registerNewDelegator(
                nodeID: nodeID,
                tokensCommitted: <-from
            )
            let set = LiquidStakingConfig.borrowOrCreateSet()
            set.insertSlot(delegator: <-delegator)
        }

        access(all) fun markDraining(slotId: UInt64) {
            LiquidStakingConfig.borrowSet().markDraining(slotId: slotId)
        }

        access(all) fun setDepositTarget(slotId: UInt64) {
            LiquidStakingConfig.borrowSet().setDepositTarget(slotId: slotId)
        }

        access(all) fun retireSlot(slotId: UInt64) {
            LiquidStakingConfig.borrowSet().retireSlot(slotId: slotId)
        }

        access(all) fun setProtocolFee(newFee: UFix64) {
            pre { newFee <= 0.2: "Protocol fee \(newFee) cannot exceed 20% (0.2)" }
            LiquidStakingConfig.protocolFeePercentQueued = newFee
            LiquidStakingConfig.protocolFeeTimelockExpiration =
                UInt64(getCurrentBlock().timestamp) + LiquidStakingConfig.protocolFeeTimelockDuration
            emit ProtocolFeeUpdateQueued(newFee: newFee)
        }

        access(all) fun activateProtocolFee() {
            pre {
                UInt64(getCurrentBlock().timestamp) >= LiquidStakingConfig.protocolFeeTimelockExpiration:
                    "Fee timelock not expired: now \(UInt64(getCurrentBlock().timestamp)) < expiration \(LiquidStakingConfig.protocolFeeTimelockExpiration)"
            }
            let newFee = LiquidStakingConfig.protocolFeePercentQueued ?? panic("No fee update queued")
            let oldFee = LiquidStakingConfig.protocolFeePercent
            LiquidStakingConfig.protocolFeePercent = newFee
            LiquidStakingConfig.protocolFeePercentQueued = nil
            EVMRoute.setProtocolFee(coa: self.borrowCoa(), vault: self.vault, fee: EVMRoute.tokenUFix64ToScaledUInt256(newFee))
            emit ProtocolFeeUpdated(oldFee: oldFee, newFee: newFee)
        }

        access(all) fun setStakingPaused(paused: Bool) {
            LiquidStakingConfig.isStakingPaused = paused
            EVMRoute.setStakingPaused(coa: self.borrowCoa(), vault: self.vault, paused: paused)
            emit StakingPauseUpdated(paused: paused)
        }

        access(all) fun setMinOperationAmount(newMin: UFix64) {
            pre { newMin > 0.0: "Minimum operation amount \(newMin) must be > 0" }
            let old = LiquidStakingConfig.minOperationAmount
            LiquidStakingConfig.minOperationAmount = newMin
            EVMRoute.setMinRequestAmount(coa: self.borrowCoa(), vault: self.vault, amount: EVMRoute.tokenUFix64ToScaledUInt256(newMin))
            emit MinStakeUpdated(oldMin: old, newMin: newMin)
        }

        access(all) fun setProtocolFeeReceiver(newReceiver: Address) {
            pre {
                getAccount(newReceiver)
                    .capabilities
                    .borrow<&{FungibleToken.Receiver}>(LiquidStakingConfig.ProtocolFeeReceiverPublicPath) != nil:
                    "Receiver \(newReceiver) does not publish a FLOW receiver at \(LiquidStakingConfig.ProtocolFeeReceiverPublicPath)"
            }
            let old = LiquidStakingConfig.protocolFeeReceiver
            LiquidStakingConfig.protocolFeeReceiver = newReceiver
            emit ProtocolFeeReceiverUpdated(oldReceiver: old, newReceiver: newReceiver)
        }

        access(all) fun setUnstakeUnlockEpochDelay(newDelay: UInt64) {
            pre { newDelay <= 2: "Unstake unlock delay \(newDelay) exceeds max 2 epochs" }
            let old = LiquidStakingConfig.unstakeUnlockEpochDelay
            LiquidStakingConfig.unstakeUnlockEpochDelay = newDelay
            emit UnstakeUnlockEpochDelayUpdated(oldDelayEpochs: old, newDelayEpochs: newDelay)
        }

        access(all) fun setSlippageTolerance(slippageTolerance: UFix64) {
            pre { slippageTolerance <= 0.01: "Slippage tolerance \(slippageTolerance) cannot exceed 1% (0.01)" }
            EVMRoute.setSlippageTolerance(
                coa: self.borrowCoa(),
                vault: self.vault,
                slippageTolerance: EVMRoute.tokenUFix64ToScaledUInt256(slippageTolerance)
            )
        }

        access(all) fun updateConfig(
            minOperationAmount: UFix64,
            paused: Bool,
            slippageTolerance: UFix64
        ) {
            pre {
                minOperationAmount > 0.0: "Minimum operation amount \(minOperationAmount) must be > 0"
                slippageTolerance <= 0.01: "Slippage tolerance \(slippageTolerance) cannot exceed 1% (0.01)"
            }
            let oldMin = LiquidStakingConfig.minOperationAmount
            LiquidStakingConfig.minOperationAmount = minOperationAmount
            LiquidStakingConfig.isStakingPaused = paused
            EVMRoute.updateConfig(
                coa: self.borrowCoa(),
                vault: self.vault,
                minRequestAmount: EVMRoute.tokenUFix64ToScaledUInt256(minOperationAmount),
                isStakingPaused: paused,
                protocolFee: EVMRoute.tokenUFix64ToScaledUInt256(LiquidStakingConfig.protocolFeePercent),
                slippageTolerance: EVMRoute.tokenUFix64ToScaledUInt256(slippageTolerance)
            )
            emit MinStakeUpdated(oldMin: oldMin, newMin: minOperationAmount)
            emit StakingPauseUpdated(paused: paused)
        }

        access(all) fun lspVaultEVMAddress(): EVM.EVMAddress {
            return self.vault
        }

        access(all) fun governanceCoaEVMAddress(): EVM.EVMAddress {
            return self.borrowCoa().address()
        }
    }

    init(
        protocolFeePercent: UFix64,
        protocolFeeReceiver: Address,
        minOperationAmount: UFix64,
        unstakeUnlockEpochDelay: UInt64,
        coa: @EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
    ) {
        pre {
            protocolFeePercent <= 0.2: "Protocol fee \(protocolFeePercent) cannot exceed 20% (0.2)"
            getAccount(protocolFeeReceiver)
                    .capabilities
                    .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver) != nil:
                    "Receiver \(protocolFeeReceiver) does not publish a FLOW receiver at /public/flowTokenReceiver"
            minOperationAmount > 0.0: "Minimum operation amount \(minOperationAmount) must be > 0"
            unstakeUnlockEpochDelay <= 2: "Unstake unlock delay \(unstakeUnlockEpochDelay) exceeds max 2 epochs"
        }
        self.protocolFeeReceiver = protocolFeeReceiver
        self.ProtocolFeeReceiverPublicPath = /public/flowTokenReceiver
        self.protocolFeePercent = protocolFeePercent
        self.protocolFeePercentQueued = nil
        self.protocolFeeTimelockDuration = 604800 // 7 days
        self.protocolFeeTimelockExpiration = 0
        self.isStakingPaused = false
        self.minOperationAmount = minOperationAmount
        self.unstakeUnlockEpochDelay = unstakeUnlockEpochDelay
        self.AdminStoragePath = /storage/liquidStakingAdmin
        self.DelegatorStoragePath = /storage/liquidStakingDelegator
        self.WithdrawPoolStoragePath = /storage/liquidStakingWithdrawPool
        self.slotStatusActive = 0
        self.slotStatusDraining = 1

        self.account.storage.save(<-create Admin(coa: <-coa, vault: vault), to: self.AdminStoragePath)
    }

    access(all) fun lspVaultEVMAddress(): EVM.EVMAddress {
        let admin =
            self.account.storage.borrow<&Admin>(from: self.AdminStoragePath)
                ?? panic("LiquidStakingConfig: admin resource missing")
        return admin.lspVaultEVMAddress()
    }

    access(all) fun governanceCoaEVMAddress(): EVM.EVMAddress {
        let admin =
            self.account.storage.borrow<&Admin>(from: self.AdminStoragePath)
                ?? panic("LiquidStakingConfig: admin resource missing")
        return admin.governanceCoaEVMAddress()
    }
}
