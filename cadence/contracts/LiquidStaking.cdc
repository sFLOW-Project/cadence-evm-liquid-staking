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

    access(all) event Staked(flowAmount: UFix64, sFlowAmount: UFix64)
    access(all) event UnstakeRequested(id: UInt64, sFlowAmount: UFix64, flowAmount: UFix64, unlockEpoch: UInt64)
    access(all) event UnstakeFulfilled(id: UInt64, flowAmount: UFix64)
    access(all) event UnstakeFlowRoutedToEvm(id: UInt64, flowAmount: UFix64)
    access(all) event RewardsCompounded(rewardAmount: UFix64, feeAmount: UFix64)
    access(all) event FlowReceiptDeposited(id: UInt64, flowAmount: UFix64, unlockEpoch: UInt64, owner: Address?)
    access(all) event FlowReceiptWithdrawn(id: UInt64, flowAmount: UFix64, unlockEpoch: UInt64, owner: Address?)

    access(all) resource FlowReceipt {
        access(all) let amount: UFix64
        access(all) let unlockEpoch: UInt64

        init(amount: UFix64, unlockEpoch: UInt64) {
            self.amount = amount
            self.unlockEpoch = unlockEpoch
        }
    }

    access(all) fun stake(from: @FlowToken.Vault): @sFlowToken.Vault {
        pre {
            LiquidStakingConfig.isStakingPaused == false: "Staking is paused"
            FlowIDTableStaking.stakingEnabled() == true: "Not in the Flow chain staking period"
            from.balance >= LiquidStakingConfig.minOperationAmount:
                "Stake amount \(from.balance) must be >= min \(LiquidStakingConfig.minOperationAmount)"
        }

        let flowAmount = from.balance
        let sFlowAmount = self.calcSFlowFromFlow(flowAmount: flowAmount)

        let delegator = self.account.storage
            .borrow<auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator>(
                from: LiquidStakingConfig.DelegatorStoragePath
            ) ?? panic("No delegator configured")

        delegator.delegateNewTokens(from: <-from)

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
            from.balance >= LiquidStakingConfig.minOperationAmount:
                "Unstake amount \(from.balance) must be >= min \(LiquidStakingConfig.minOperationAmount)"
        }

        let sFlowAmount = from.balance
        let flowAmount = self.calcFlowFromSFlow(sFlowAmount: sFlowAmount)

        sFlowToken.burnTokens(from: <-from)

        let delegator = self.account.storage
            .borrow<auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator>(
                from: LiquidStakingConfig.DelegatorStoragePath
            ) ?? panic("No delegator configured")

        delegator.requestUnstaking(amount: flowAmount)

        self.totalFlowStaked = self.totalFlowStaked - flowAmount

        let unlockEpoch = FlowEpoch.currentEpochCounter + 2

        let receipt <- create FlowReceipt(amount: flowAmount, unlockEpoch: unlockEpoch)

        emit UnstakeRequested(id: receipt.uuid, sFlowAmount: sFlowAmount, flowAmount: flowAmount, unlockEpoch: unlockEpoch)

        return <- receipt
    }

    access(all) fun withdraw(receipt: @FlowReceipt): @FlowToken.Vault {
        pre {
            /// Setting unstakeUnlockEpochDelay allows admin to apply delay to the currently pending requests
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch + LiquidStakingConfig.unstakeUnlockEpochDelay:
                "Unstake not unlocked: epoch \(FlowEpoch.currentEpochCounter) < unlock \(receipt.unlockEpoch) + delay \(LiquidStakingConfig.unstakeUnlockEpochDelay)"
        }

        emit UnstakeFulfilled(id: receipt.uuid, flowAmount: receipt.amount)

        let delegator = self.account.storage
            .borrow<auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator>(
                from: LiquidStakingConfig.DelegatorStoragePath
            ) ?? panic("No delegator configured")

        let flowVault <- delegator.withdrawUnstakedTokens(amount: receipt.amount) as! @FlowToken.Vault

        destroy receipt

        return <- flowVault
    }

    /// Admin recovery withdraw for stuck EVM unstake receipts (`RelayerRouter.evictStuckReceipt`).
    /// Differs from `withdraw`:
    ///   - Honors base `receipt.unlockEpoch` only (ignores retroactive `unstakeUnlockEpochDelay`).
    ///   - Pulls `min(receipt.amount, tokensUnstaked)` when the delegator bucket is short.
    access(account) fun withdrawStuckReceipt(receipt: @FlowReceipt): @FlowToken.Vault {
        pre {
            FlowEpoch.currentEpochCounter >= receipt.unlockEpoch:
                "Base unstake unlock epoch not reached: epoch \(FlowEpoch.currentEpochCounter) < \(receipt.unlockEpoch)"
        }

        let delegator = self.account.storage
            .borrow<auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator>(
                from: LiquidStakingConfig.DelegatorStoragePath
            ) ?? panic("No delegator configured")

        let info = FlowIDTableStaking.DelegatorInfo(
            nodeID: delegator.nodeID,
            delegatorID: delegator.id
        )

        var withdrawAmount = receipt.amount
        if info.tokensUnstaked < withdrawAmount {
            withdrawAmount = info.tokensUnstaked
        }

        assert(
            withdrawAmount > 0.0,
            message: "No unstaked FLOW available for stuck receipt (requested \(receipt.amount), tokensUnstaked \(info.tokensUnstaked))"
        )

        emit UnstakeFulfilled(id: receipt.uuid, flowAmount: withdrawAmount)

        let flowVault <- delegator.withdrawUnstakedTokens(amount: withdrawAmount) as! @FlowToken.Vault

        destroy receipt

        return <- flowVault
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

        let delegator = self.account.storage
            .borrow<auth(FlowIDTableStaking.DelegatorOwner) &FlowIDTableStaking.NodeDelegator>(
                from: LiquidStakingConfig.DelegatorStoragePath
            ) ?? panic("No delegator configured")

        let info = FlowIDTableStaking.DelegatorInfo(
            nodeID: delegator.nodeID,
            delegatorID: delegator.id
        )
        let rewardAmount = info.tokensRewarded
        if rewardAmount <= 0.0 { return }

        let feeAmount = rewardAmount * LiquidStakingConfig.protocolFeePercent
        let restakeAmount = rewardAmount - feeAmount

        if feeAmount > 0.0 {
            let feeVault <- delegator.withdrawRewardedTokens(amount: feeAmount)
            let treasury = getAccount(LiquidStakingConfig.protocolFeeReceiver)
                .capabilities
                .borrow<&{FungibleToken.Receiver}>(LiquidStakingConfig.ProtocolFeeReceiverPublicPath)
                ?? panic("Protocol fee receiver not found at public path (publish FLOW receiver there)")
            treasury.deposit(from: <- feeVault)
        }

        delegator.delegateRewardedTokens(amount: restakeAmount)
        self.totalFlowStaked = self.totalFlowStaked + restakeAmount

        emit RewardsCompounded(rewardAmount: rewardAmount, feeAmount: feeAmount)
    }

    access(all) fun getDelegatorInfo(): FlowIDTableStaking.DelegatorInfo {
        let delegator = self.account.storage
            .borrow<&FlowIDTableStaking.NodeDelegator>(from: LiquidStakingConfig.DelegatorStoragePath)
            ?? panic("No delegator configured")
        return FlowIDTableStaking.DelegatorInfo(
            nodeID: delegator.nodeID,
            delegatorID: delegator.id
        )
    }

    access(all) view fun flowPerSFlow(): UFix64 {
        if self.totalFlowStaked == 0.0 { return 1.0 }
        if sFlowToken.totalSupply == 0.0 { return 1.0 }
        let backingScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(self.totalFlowStaked)
        let supplyScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowToken.totalSupply)
        let ratioScaled =
            backingScaled * EVMRoute.ratioScaleFactor / supplyScaled
        return EVMRoute.ratioScaled1e18ToUFix64(ratioScaled)
    }

    access(all) view fun sFlowPerFlow(): UFix64 {
        if self.totalFlowStaked == 0.0 { return 1.0 }
        if sFlowToken.totalSupply == 0.0 { return 1.0 }
        let backingScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(self.totalFlowStaked)
        let supplyScaled =
            EVMRoute.tokenUFix64ToScaledUInt256(sFlowToken.totalSupply)
        let ratioScaled =
            supplyScaled * EVMRoute.ratioScaleFactor / backingScaled
        return EVMRoute.ratioScaled1e18ToUFix64(ratioScaled)
    }

    access(all) view fun calcSFlowFromFlow(flowAmount: UFix64): UFix64 {
        if self.totalFlowStaked <= 0.0 || sFlowToken.totalSupply <= 0.0 {
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
        let pool <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        self.account.storage.save(<-pool, to: LiquidStakingConfig.WithdrawPoolStoragePath)
    }
}
