import "LiquidStaking"
import "LiquidStakingConfig"
import "EVM"
import "EVMRoute"
import "FlowToken"
import "FungibleToken"
import "sFlowToken"

import "FlowEVMBridge"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"

/// Permissionless relayer router: single Cadence entry for **native** `stake` / `unstake` / `withdraw` and **EVM** request queues via protocol COA.
/// Slippage-cancel compensation uses the same FLOW estimate as bridge fee onboarding (`approxFee`).
/// EVM `coa.call` paths and ABI helpers live in `EVMRoute`.
/// **Unstake initiation** deposits bridged sFlow into the protocol account’s primary `@sFlowToken.Vault` at
/// `sFlowToken.tokenVaultPath` (provision once via `cadence/transactions/deployment/setup_protocol_flow_and_sflow_vaults.cdc`).
access(all) contract RelayerRouter {

    /// EVM `RequestStatus`: NONE=0, QUEUED=1, AWAITING_FULFILLMENT=2, UNSTAKE_CONFIRMED=3, FULFILLED=4, CANCELLED=5
    access(all) let evmRequestQueued: UInt8
    access(all) let evmAwaitingFulfillment: UInt8
    access(all) let evmUnstakeConfirmed: UInt8
    access(all) let evmRequestFulfilled: UInt8
    access(all) let evmRequestCancelled: UInt8

    access(self) var evmRequestIdToReceipt: @{UInt256: LiquidStaking.FlowReceipt}

    access(all) event StuckReceiptEvicted(
        unstakeRequestId: UInt256,
        receiptUuid: UInt64,
        flowAmount: UFix64,
        flowReturned: UFix64
    )

    access(self) let evmVaultHex: String
    access(self) let evmSFlowHex: String
    access(self) let vaultIdentifier: String
    access(self) let coa: @EVM.CadenceOwnedAccount

    access(self) fun borrowCoa(): auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount {
        return (&self.coa)
    }

    access(self) fun vaultAddr(): EVM.EVMAddress {
        return EVMRoute.evmAddress(hex: self.evmVaultHex)
    }

    access(self) fun sFlowEvmAddr(): EVM.EVMAddress {
        return EVMRoute.evmAddress(hex: self.evmSFlowHex)
    }

    access(self) fun fulfillStakeInternal(
        stakeRequestId: UInt256,
        feeProvider: auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
    ) {
        let vaultAddr = self.vaultAddr()
        let sFlowAddr = self.sFlowEvmAddr()
        let coa = self.borrowCoa()

        let request = EVMRoute.readStakeRequest(coa: coa, vault: vaultAddr, id: stakeRequestId)
        assert(
            request.status == self.evmRequestQueued,
            message: "Stake request \(stakeRequestId) status \(request.status), expected QUEUED (\(self.evmRequestQueued))"
        )

        EVMRoute.withdrawPendingStakeNative(
            coa: coa,
            vault: vaultAddr,
            stakeRequestId: stakeRequestId
        )

        let statusAfterWithdraw = EVMRoute.readStakeRequest(coa: coa, vault: vaultAddr, id: stakeRequestId).status
        assert(
            statusAfterWithdraw == self.evmAwaitingFulfillment,
            message: "Stake request \(stakeRequestId) status \(statusAfterWithdraw), expected AWAITING_FULFILLMENT (\(self.evmAwaitingFulfillment))"
        )

        let withdrawBalance = EVM.Balance(attoflow: UInt(request.amount))
        var flowVault <- coa.withdraw(balance: withdrawBalance)

        let quoteWei = EVMRoute.ufix64FlowToWeiUInt256(
            LiquidStaking.calcSFlowFromFlow(flowAmount: flowVault.balance)
        )

        if quoteWei < request.minAmountOut {
            let flowAmountAtto = EVMRoute.ufix64FlowToAttoUInt(flowVault.balance)
            coa.deposit(from: <-flowVault)
            EVMRoute.cancelStakeRequestSlippage(
                coa: coa,
                vault: vaultAddr,
                stakeRequestId: stakeRequestId,
                refundAtto: flowAmountAtto
            )
            let cancelledStatus = EVMRoute.readStakeRequest(coa: coa, vault: vaultAddr, id: stakeRequestId).status
            assert(
                cancelledStatus == self.evmRequestCancelled,
                message: "Stake request \(stakeRequestId) status \(cancelledStatus), expected CANCELLED (\(self.evmRequestCancelled))"
            )
            return
        }

        let sFlowVault <- LiquidStaking.stake(from: <-flowVault)

        assert(
            sFlowVault.getType().identifier == self.vaultIdentifier,
            message: "sFlow vault type \(sFlowVault.getType().identifier) != expected \(self.vaultIdentifier)"
        )

        let sFlowOutWei = EVMRoute.ufix64FlowToWeiUInt256(sFlowVault.balance)

        coa.depositTokens(
            vault: <-sFlowVault,
            feeProvider: feeProvider
        )

        EVMRoute.transferSFlowToVault(
            coa: coa,
            sFlow: sFlowAddr,
            vault: vaultAddr,
            amountWei: sFlowOutWei
        )

        EVMRoute.fulfillStakeRequest(
            coa: coa,
            vault: vaultAddr,
            stakeRequestId: stakeRequestId,
            sFlowAmountWei: sFlowOutWei
        )

        let fulfilledStatus = EVMRoute.readStakeRequest(coa: coa, vault: vaultAddr, id: stakeRequestId).status
        assert(
            fulfilledStatus == self.evmRequestFulfilled,
            message: "Stake request \(stakeRequestId) status \(fulfilledStatus), expected FULFILLED (\(self.evmRequestFulfilled))"
        )
    }

    access(self) fun initiateUnstakeInternal(
        unstakeRequestId: UInt256,
        feeProvider: auth(FungibleToken.Withdraw) &{FungibleToken.Provider},
    ) {
        let coa = self.borrowCoa()
        let vaultAddr = self.vaultAddr()

        let request = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId)
        assert(
            request.status == self.evmRequestQueued,
            message: "Unstake request \(unstakeRequestId) status \(request.status), expected QUEUED (\(self.evmRequestQueued))"
        )

        EVMRoute.withdrawPendingUnstakeSFlow(
            coa: coa,
            vault: vaultAddr,
            id: unstakeRequestId
        )

        let statusAfterWithdraw = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId).status
        assert(
            statusAfterWithdraw == self.evmAwaitingFulfillment,
            message: "Unstake request \(unstakeRequestId) status \(statusAfterWithdraw), expected AWAITING_FULFILLMENT (\(self.evmAwaitingFulfillment))"
        )

        let sFlowVault <- coa.withdrawTokens(
            type: Type<@sFlowToken.Vault>(),
            amount: request.amount,
            feeProvider: feeProvider
        ) as! @sFlowToken.Vault
        
        let receipt <- LiquidStaking.unstake(from: <-sFlowVault)

        EVMRoute.confirmUnstakeRequest(
            coa: coa,
            vault: vaultAddr,
            id: unstakeRequestId,
            flowAmount: EVMRoute.ufix64FlowToWeiUInt256(receipt.amount),
            unlockEpoch: UInt256(receipt.unlockEpoch)
        )

        let confirmedStatus = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId).status
        assert(
            confirmedStatus == self.evmUnstakeConfirmed,
            message: "Unstake request \(unstakeRequestId) status \(confirmedStatus), expected UNSTAKE_CONFIRMED (\(self.evmUnstakeConfirmed))"
        )

        let replaced <- self.evmRequestIdToReceipt.insert(key: unstakeRequestId, <-receipt)

        assert(
            replaced == nil,
            message: "Unstake request \(unstakeRequestId) already has a stored receipt"
        )
        destroy replaced
    }

    access(self) fun finalizeUnstakeInternal(unstakeRequestId: UInt256) {
        let coa = self.borrowCoa()
        let vaultAddr = self.vaultAddr()

        let request = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId)
        assert(
            request.status == self.evmUnstakeConfirmed,
            message: "Unstake request \(unstakeRequestId) status \(request.status), expected UNSTAKE_CONFIRMED (\(self.evmUnstakeConfirmed))"
        )

        let receiptOpt <- self.evmRequestIdToReceipt.remove(key: unstakeRequestId)
        let receipt <- receiptOpt ?? panic("No stored receipt for unstake request \(unstakeRequestId)")
        
        let receiptAmount = EVMRoute.ufix64FlowToWeiUInt256(receipt.amount)

        let flowVault <- LiquidStaking.withdraw(receipt: <-receipt)

        coa.deposit(from: <-flowVault)

        EVMRoute.sendNativeValue(
            coa: coa,
            to: vaultAddr,
            attoflowAmount: UInt(receiptAmount)
        )

        EVMRoute.fulfillUnstakeRequest(
            coa: coa,
            vault: vaultAddr,
            id: unstakeRequestId
        )

        let finalizedStatus = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId).status
        assert(
            finalizedStatus == self.evmRequestFulfilled,
            message: "Unstake request \(unstakeRequestId) status \(finalizedStatus), expected FULFILLED (\(self.evmRequestFulfilled))"
        )
    }

    /// Admin escape hatch when a stored receipt cannot be cleared via permissionless finalization.
    /// Uses `LiquidStaking.withdrawStuckReceipt`, which ignores retroactive unlock delay and
    /// withdraws up to available unstaked FLOW when the delegator bucket is short.
    access(all) fun evictStuckReceipt(
        unstakeRequestId: UInt256,
        admin: &LiquidStakingConfig.Admin
    ) {
        let _ = admin
        self.evictStuckReceiptInternal(unstakeRequestId: unstakeRequestId)
    }

    access(self) fun evictStuckReceiptInternal(unstakeRequestId: UInt256) {
        let coa = self.borrowCoa()
        let vaultAddr = self.vaultAddr()

        let request = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId)
        assert(
            request.status == self.evmUnstakeConfirmed,
            message: "Unstake request \(unstakeRequestId) status \(request.status), expected UNSTAKE_CONFIRMED (\(self.evmUnstakeConfirmed))"
        )

        let receiptOpt <- self.evmRequestIdToReceipt.remove(key: unstakeRequestId)
        let receipt <- receiptOpt ?? panic("No stored receipt for unstake request \(unstakeRequestId)")

        let receiptUuid = receipt.uuid
        let flowAmount = receipt.amount

        let flowVault <- LiquidStaking.withdrawStuckReceipt(receipt: <-receipt)
        let flowReturned = flowVault.balance
        let flowReturnedWei = EVMRoute.ufix64FlowToWeiUInt256(flowReturned)

        coa.deposit(from: <-flowVault)

        EVMRoute.sendNativeValue(
            coa: coa,
            to: vaultAddr,
            attoflowAmount: UInt(flowReturnedWei)
        )

        EVMRoute.fulfillUnstakeRequest(
            coa: coa,
            vault: vaultAddr,
            id: unstakeRequestId
        )

        let evictedStatus = EVMRoute.readUnstakeRequest(coa: coa, vault: vaultAddr, id: unstakeRequestId).status
        assert(
            evictedStatus == self.evmRequestFulfilled,
            message: "Unstake request \(unstakeRequestId) status \(evictedStatus), expected FULFILLED (\(self.evmRequestFulfilled))"
        )

        emit StuckReceiptEvicted(
            unstakeRequestId: unstakeRequestId,
            receiptUuid: receiptUuid,
            flowAmount: flowAmount,
            flowReturned: flowReturned
        )
    }

    access(all) fun compoundAndSyncRate() {
        let coa = self.borrowCoa()

        LiquidStaking.compoundRewards()

        let newRate = LiquidStaking.flowPerSFlow()
        let rateScaled = EVMRoute.ufix64FlowToWeiUInt256(newRate)
        EVMRoute.syncRate(
            coa: coa,
            vault: self.vaultAddr(),
            rateScaled: rateScaled
        )
    }

    access(all) fun handleStakes(
        stakeRequestIds: [UInt256],
        feeProvider: auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
    ) {
        for stakeRequestId in stakeRequestIds {
            self.fulfillStakeInternal(
                stakeRequestId: stakeRequestId,
                feeProvider: feeProvider
            )
        }
    }

    access(all) fun initiateUnstakes(
        unstakeRequestIds: [UInt256],
        feeProvider: auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
    ) {
        for evmUnstakeRequestId in unstakeRequestIds {
            self.initiateUnstakeInternal(
                unstakeRequestId: evmUnstakeRequestId,
                feeProvider: feeProvider,
            )
        }
    }

    access(all) fun finalizeUnstakes(unstakeRequestIds: [UInt256]) {
        for unstakeRequestId in unstakeRequestIds {
            self.finalizeUnstakeInternal(unstakeRequestId: unstakeRequestId)
        }
    }

    init(
        coa: @EVM.CadenceOwnedAccount,
        evmVaultHex: String,
        evmSFlowHex: String,
        vaultIdentifier: String,
    ) {
        let vaultType = CompositeType(vaultIdentifier)
            ?? panic("RelayerRouter.Router: invalid vaultIdentifier")
        let needsBridgeOnboard = FlowEVMBridge.typeRequiresOnboarding(vaultType)
            ?? panic("RelayerRouter.Router: FlowEVMBridge does not support vault type")
        assert(
            !needsBridgeOnboard,
            message: "RelayerRouter.Router: onboard vault type for Flow EVM bridge before install (cadence/transactions/deployment/onboard_sflow_token_type_for_evm_bridge.cdc)"
        )
        let bridgedSFlow = FlowEVMBridge.getAssociatedEVMAddress(with: vaultType)
            ?? panic("RelayerRouter.Router: no FlowEVMBridge token association for vault type")
        assert(
            bridgedSFlow.toString() == EVMRoute.evmAddress(hex: evmSFlowHex).toString(),
            message: "evmSFlowHex \(evmSFlowHex) != FlowEVMBridge association \(bridgedSFlow.toString())"
        )

        self.coa <- coa
        self.evmVaultHex = evmVaultHex
        self.evmSFlowHex = evmSFlowHex
        self.vaultIdentifier = vaultIdentifier
        self.evmRequestQueued = 1
        self.evmAwaitingFulfillment = 2
        self.evmUnstakeConfirmed = 3
        self.evmRequestFulfilled = 4
        self.evmRequestCancelled = 5
        self.evmRequestIdToReceipt <- {}
    }
}