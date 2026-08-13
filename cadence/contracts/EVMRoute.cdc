import "EVM"

/// LSP EVM surface: ABI encode/decode helpers and `coa.call` wrappers for `LSPVault` / sFlow ERC-20.
///
/// **`ratioScaleFactor`** and token/`UInt256` conversion helpers are the single source for Cadence ↔ EVM amount lanes
/// and for **`LiquidStaking`** exchange-rate math (`flowPerSFlow`, mint/redeem).
///

access(all) contract EVMRoute {

    /// Fixed-point scale for ratio quotes (`≈ 1e18`), aligned with common Solidity integrations.
    access(all) let ratioScaleFactor: UInt256

    /// `coa.call` gas budgets — tune in `init` after Flow EVM repricing or integration tests.
    access(all) let gasLimitViewCount: UInt64
    access(all) let gasLimitViewRequest: UInt64
    access(all) let gasLimitWithdrawPendingStake: UInt64
    access(all) let gasLimitCancelStakeSlippage: UInt64
    access(all) let gasLimitErc20Transfer: UInt64
    access(all) let gasLimitFulfillStake: UInt64
    access(all) let gasLimitSyncRate: UInt64
    access(all) let gasLimitWithdrawPendingUnstake: UInt64
    access(all) let gasLimitConfirmUnstake: UInt64
    access(all) let gasLimitSendNative: UInt64
    access(all) let gasLimitFulfillUnstake: UInt64
    access(all) let gasLimitAdminSetter: UInt64
    access(all) let gasLimitUpdateConfig: UInt64

    access(all) struct StakeRequestRead {
        access(all) let status: UInt8
        access(all) let amount: UInt256
        access(all) let minAmountOut: UInt256
        init(status: UInt8, amount: UInt256, minAmountOut: UInt256) {
            self.status = status
            self.amount = amount
            self.minAmountOut = minAmountOut
        }
    }

    access(all) struct UnstakeRequestRead {
        access(all) let status: UInt8
        access(all) let amount: UInt256
        init(status: UInt8, amount: UInt256) {
            self.status = status
            self.amount = amount
        }
    }

    /// ABI-decoded `LSPVault.getConfig()` / `ILSPVaultConfig.Config`.
    access(all) struct VaultConfigRead {
        access(all) let minRequestAmount: UInt256
        access(all) let isStakingPaused: Bool
        access(all) let protocolFee: UInt256
        access(all) let slippageTolerance: UInt256
        init(
            minRequestAmount: UInt256,
            isStakingPaused: Bool,
            protocolFee: UInt256,
            slippageTolerance: UInt256
        ) {
            self.minRequestAmount = minRequestAmount
            self.isStakingPaused = isStakingPaused
            self.protocolFee = protocolFee
            self.slippageTolerance = slippageTolerance
        }
    }

    access(all) fun evmAddress(hex: String): EVM.EVMAddress {
        return EVM.addressFromString(hex)
    }

    /// `wordIndex`-th 32-byte big-endian ABI word (`wordIndex` 0 = bytes 0..31).
    access(all) fun abiWordUInt256(_ data: [UInt8], wordIndex: UInt64): UInt256 {
        let offset = Int(wordIndex) * 32
        assert(data.length >= offset + 32, message: "short ABI word")
        var v: UInt256 = 0
        var i = 0
        while i < 32 {
            v = v * 256 + UInt256(data[offset + i])
            i = i + 1
        }
        return v
    }

    // ──── Scaled math (`UInt256` wei lane + exchange-ratio helpers) ────

    /// Token **`UFix64`** → wei-style **`UInt256`** (single definition backing **`ufix64FlowToWeiUInt256`**).
    access(all) view fun tokenUFix64ToScaledUInt256(_ value: UFix64): UInt256 {
        let scaleNano = UInt256(100_000_000)
        let outer = UInt256(10_000_000_000)

        let intFlow = UInt64(value)
        let frac: UFix64 = value - UFix64(intFlow)
        assert(frac >= 0.0 && frac < 1.0, message: "EVMRoute: token amount fractional part out of range")

        let intNano = UInt256(intFlow) * scaleNano
        let fracNano = UInt256(UInt64(frac * 100_000_000.0))
        return (intNano + fracNano) * outer
    }

    /// Inverse of **`tokenUFix64ToScaledUInt256`** (truncates sub-1e-8-FLOW wei remainder).
    ///
    /// Decodes wei-style **`UInt256`** amounts by splitting whole FLOW and the 8-decimal
    /// fractional lane instead of materializing **`scaled / 1e10`** as a single **`UInt64`**.
    access(all) view fun scaledUInt256ToTokenUFix64(_ scaled: UInt256): UFix64 {
        let MAX_FRACTIONAL_PART: UInt256 = 9551615
        let weiFactor = UInt256(1_000_000_000_000_000_000)
        let subNano = UInt256(10_000_000_000)

        let whole = scaled / weiFactor
        let rem = scaled % weiFactor
        let frac8 = rem / subNano

        assert(
            whole < UInt256(UFix64.max) || (whole == UInt256(UFix64.max) && frac8 <= MAX_FRACTIONAL_PART),
            message: "scaled token exceeds UFix64.max"
        )

        return UFix64(UInt64(whole)) + UFix64(UInt64(frac8)) / 100_000_000.0
    }

    /// Convert **`ratioScaled`** (approximately `trueRatio * ratioScaleFactor`) to **`UFix64`**.
    access(all) view fun ratioScaled1e18ToUFix64(_ ratioScaled: UInt256): UFix64 {
        let scale = self.ratioScaleFactor
        let MAX_FRACTIONAL_PART: UInt256 = 9551615
        let whole = ratioScaled / scale
        let rem = ratioScaled % scale
        let frac8 = rem * 100_000_000 / scale

        assert(
            whole < UInt256(UFix64.max) || (whole == UInt256(UFix64.max) && frac8 <= MAX_FRACTIONAL_PART),
            message: "ratioScaled exceeds UFix64.max"
        )

        return UFix64(UInt64(whole)) + UFix64(UInt64(frac8)) / 100_000_000.0
    }

    access(all) fun u256ToUIntAttoflow(_ v: UInt256): UInt {
        return UInt(v)
    }

    access(all) fun ufix64FlowToAttoUInt(_ v: UFix64): UInt {
        return UInt(self.tokenUFix64ToScaledUInt256(v))
    }

    access(all) fun ufix64FlowToWeiUInt256(_ v: UFix64): UInt256 {
        return self.tokenUFix64ToScaledUInt256(v)
    }

    access(all) fun readStakeRequest(
        coa: &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        id: UInt256
    ): StakeRequestRead {
        let STAKE_REQUEST_RETURNDATA_LENGTH = 160
        let calldata = EVM.encodeABIWithSignature("stakeRequests(uint256)", [id])
        let res = coa.dryCall(
            to: vault,
            data: calldata,
            gasLimit: self.gasLimitViewRequest,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "stakeRequests call failed")
        let d = res.data
        assert(d.length >= STAKE_REQUEST_RETURNDATA_LENGTH, message: "short stakeRequests returndata")
        let status = d[31]
        let amount = self.abiWordUInt256(d, wordIndex: 2)
        let minAmountOut = self.abiWordUInt256(d, wordIndex: 3)
        return StakeRequestRead(status: status, amount: amount, minAmountOut: minAmountOut)
    }

    access(all) fun readVaultConfig(
        coa: &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress
    ): VaultConfigRead {
        let CONFIG_RETURNDATA_LENGTH = 128
        let calldata = EVM.encodeABIWithSignature("getConfig()", [])
        let res = coa.dryCall(
            to: vault,
            data: calldata,
            gasLimit: self.gasLimitViewRequest,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "getConfig call failed")
        let d = res.data
        assert(d.length >= CONFIG_RETURNDATA_LENGTH, message: "short getConfig returndata")
        let pausedWord = self.abiWordUInt256(d, wordIndex: 1)
        assert(pausedWord <= 1, message: "getConfig: invalid isStakingPaused encoding")
        return VaultConfigRead(
            minRequestAmount: self.abiWordUInt256(d, wordIndex: 0),
            isStakingPaused: pausedWord == 1,
            protocolFee: self.abiWordUInt256(d, wordIndex: 2),
            slippageTolerance: self.abiWordUInt256(d, wordIndex: 3)
        )
    }

    access(all) fun readUnstakeRequest(
        coa: &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        id: UInt256
    ): UnstakeRequestRead {
        let UNSTAKE_REQUEST_RETURNDATA_LENGTH = 192
        let calldata = EVM.encodeABIWithSignature("unstakeRequests(uint256)", [id])
        let res = coa.dryCall(
            to: vault,
            data: calldata,
            gasLimit: self.gasLimitViewRequest,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "unstakeRequests call failed")
        let d = res.data
        assert(d.length >= UNSTAKE_REQUEST_RETURNDATA_LENGTH, message: "short unstakeRequests returndata")
        let status = d[31]
        let amount = self.abiWordUInt256(d, wordIndex: 2)
        return UnstakeRequestRead(status: status, amount: amount)
    }

    access(all) fun withdrawPendingStakeNative(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        stakeRequestId: UInt256
    ) {
        let pullData = EVM.encodeABIWithSignature("withdrawPendingStakeNative(uint256)", [stakeRequestId])
        let pullRes = coa.call(
            to: vault,
            data: pullData,
            gasLimit: self.gasLimitWithdrawPendingStake,
            value: EVM.Balance(attoflow: 0)
        )
        assert(pullRes.status == EVM.Status.successful, message: "withdrawPendingStakeNative failed")
    }

    access(all) fun cancelStakeRequestSlippage(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        stakeRequestId: UInt256,
        refundAtto: UInt
    ) {
        let cancelData = EVM.encodeABIWithSignature(
            "cancelStakeRequestSlippage(uint256)",
            [stakeRequestId]
        )
        let cancelRes = coa.call(
            to: vault,
            data: cancelData,
            gasLimit: self.gasLimitCancelStakeSlippage,
            value: EVM.Balance(attoflow: refundAtto)
        )
        assert(cancelRes.status == EVM.Status.successful, message: "cancelStakeRequestSlippage failed")
    }

    /// ERC-20 `transfer(lspVault, amount)` to move bridged sFlow into `LSPVault`.
    access(all) fun transferSFlowToVault(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        sFlow: EVM.EVMAddress,
        vault: EVM.EVMAddress,
        amountWei: UInt256
    ) {
        let xferData = EVM.encodeABIWithSignature(
            "transfer(address,uint256)",
            [vault, amountWei]
        )
        let xferRes = coa.call(
            to: sFlow,
            data: xferData,
            gasLimit: self.gasLimitErc20Transfer,
            value: EVM.Balance(attoflow: 0)
        )
        assert(xferRes.status == EVM.Status.successful, message: "ERC20.transfer to LSPVault failed")
    }

    access(all) fun fulfillStakeRequest(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        stakeRequestId: UInt256,
        sFlowAmountWei: UInt256
    ) {
        let fulfillData = EVM.encodeABIWithSignature(
            "fulfillStakeRequest(uint256,uint256)",
            [stakeRequestId, sFlowAmountWei]
        )
        let fulfillRes = coa.call(
            to: vault,
            data: fulfillData,
            gasLimit: self.gasLimitFulfillStake,
            value: EVM.Balance(attoflow: 0)
        )
        assert(fulfillRes.status == EVM.Status.successful, message: "fulfillStakeRequest failed")
    }

    access(all) fun syncRate(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        rateScaled: UInt256
    ) {
        let data = EVM.encodeABIWithSignature("syncRate(uint256)", [rateScaled])
        let result = coa.call(
            to: vault,
            data: data,
            gasLimit: self.gasLimitSyncRate,
            value: EVM.Balance(attoflow: 0)
        )
        assert(result.status == EVM.Status.successful, message: "syncRate call failed")
    }

    access(all) fun withdrawPendingUnstakeSFlow(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        id: UInt256
    ) {
        let pullData = EVM.encodeABIWithSignature("withdrawPendingUnstakeSFlow(uint256)", [id])
        let pullRes = coa.call(
            to: vault,
            data: pullData,
            gasLimit: self.gasLimitWithdrawPendingUnstake,
            value: EVM.Balance(attoflow: 0)
        )
        assert(pullRes.status == EVM.Status.successful, message: "withdrawPendingUnstakeSFlow failed")
    }

    access(all) fun confirmUnstakeRequest(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        id: UInt256,
        flowAmount: UInt256,
        unlockEpoch: UInt256
    ) {
        let confirmData = EVM.encodeABIWithSignature("confirmUnstakeRequest(uint256,uint256,uint256)", [id, flowAmount, unlockEpoch])
        let confirmRes = coa.call(
            to: vault,
            data: confirmData,
            gasLimit: self.gasLimitConfirmUnstake,
            value: EVM.Balance(attoflow: 0)
        )
        assert(confirmRes.status == EVM.Status.successful, message: "confirmUnstakeRequest failed")
    }

    access(all) fun sendNativeValue(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        to: EVM.EVMAddress,
        attoflowAmount: UInt
    ) {
        let sendRes = coa.call(
            to: to,
            data: [],
            gasLimit: self.gasLimitSendNative,
            value: EVM.Balance(attoflow: attoflowAmount)
        )
        assert(sendRes.status == EVM.Status.successful, message: "Native FLOW transfer failed")
    }

    access(all) fun fulfillUnstakeRequest(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        id: UInt256,
        attoflowAmount: UInt
    ) {
        let fdata = EVM.encodeABIWithSignature(
            "fulfillUnstakeRequest(uint256)",
            [id]
        )
        let res = coa.call(
            to: vault,
            data: fdata,
            gasLimit: self.gasLimitFulfillUnstake,
            value: EVM.Balance(attoflow: attoflowAmount)
        )
        assert(res.status == EVM.Status.successful, message: "fulfillUnstakeRequest failed")
    }

    /// Recovery fulfill when Cadence returned less FLOW than `req.flowAmount`.
    /// Credits `attoflowAmount` on EVM (`LSPVault.fulfillUnstakeRequestPartial`).
    access(all) fun fulfillUnstakeRequestPartial(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        id: UInt256,
        attoflowAmount: UInt
    ) {
        let fdata = EVM.encodeABIWithSignature(
            "fulfillUnstakeRequestPartial(uint256)",
            [id]
        )
        let res = coa.call(
            to: vault,
            data: fdata,
            gasLimit: self.gasLimitFulfillUnstake,
            value: EVM.Balance(attoflow: attoflowAmount)
        )
        assert(res.status == EVM.Status.successful, message: "fulfillUnstakeRequestPartial failed")
    }

    init() {
        self.ratioScaleFactor = 1_000_000_000_000_000_000
        self.gasLimitViewCount = 50_000
        self.gasLimitViewRequest = 100_000
        self.gasLimitWithdrawPendingStake = 200_000
        self.gasLimitCancelStakeSlippage = 400_000
        self.gasLimitErc20Transfer = 200_000
        self.gasLimitFulfillStake = 500_000
        self.gasLimitSyncRate = 100_000
        self.gasLimitWithdrawPendingUnstake = 300_000
        self.gasLimitConfirmUnstake = 500_000
        self.gasLimitSendNative = 100_000
        self.gasLimitFulfillUnstake = 600_000
        self.gasLimitAdminSetter = 100_000
        self.gasLimitUpdateConfig = 200_000
    }

    access(account) fun setProtocolFee(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        fee: UInt256
    ) {
        let data = EVM.encodeABIWithSignature("setProtocolFee(uint256)", [fee])
        let res = coa.call(
            to: vault,
            data: data,
            gasLimit: self.gasLimitAdminSetter,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "setProtocolFee call failed")
    }
    
    access(account) fun setStakingPaused(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        paused: Bool
    ) {
        let data = EVM.encodeABIWithSignature("setIsStakingPaused(bool)", [paused])
        let res = coa.call(
            to: vault,
            data: data,
            gasLimit: self.gasLimitAdminSetter,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "setIsStakingPaused call failed")
    }

    access(account) fun setMinRequestAmount(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        amount: UInt256
    ) {
        let data = EVM.encodeABIWithSignature("setMinRequestAmount(uint256)", [amount])
        let res = coa.call(
            to: vault,
            data: data,
            gasLimit: self.gasLimitAdminSetter,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "setMinRequestAmount call failed")
    }

    access(account) fun setSlippageTolerance(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        slippageTolerance: UInt256
    ) {
        let data = EVM.encodeABIWithSignature("setSlippageTolerance(uint256)", [slippageTolerance])
        let res = coa.call(
            to: vault,
            data: data,
            gasLimit: self.gasLimitAdminSetter,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "setSlippageTolerance call failed")
    }
    access(account) fun updateConfig(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        minRequestAmount: UInt256,
        isStakingPaused: Bool,
        protocolFee: UInt256,
        slippageTolerance: UInt256
    ) {
        let cfg = VaultConfigRead(
            minRequestAmount: minRequestAmount,
            isStakingPaused: isStakingPaused,
            protocolFee: protocolFee,
            slippageTolerance: slippageTolerance
        )
        let data = EVM.encodeABIWithSignature(
            "updateConfig((uint256,bool,uint256,uint256))",
            [cfg]
        )
        let res = coa.call(
            to: vault,
            data: data,
            gasLimit: self.gasLimitUpdateConfig,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "updateConfig call failed")
    }
}
