import "FlowToken"
import "FungibleToken"
import "FlowIDTableStaking"

/// Test-only stub that stands in for `cadence/contracts/LiquidStakingConfig.cdc`
/// when exercising `LiquidStaking.cdc` in `flow test`.
///
/// It mirrors **the entire non-EVM surface** of the real contract:
///   - Init preconditions (`protocolFeePercent <= 0.2`, non-zero receiver / min,
///     `unstakeUnlockEpochDelay <= 2`)
///   - All public field names + storage paths that production code reads
///     (`isStakingPaused`, `minOperationAmount`, `unstakeUnlockEpochDelay`,
///     `protocolFeePercent`, `protocolFeePercentQueued`,
///     `protocolFeeTimelockDuration`, `protocolFeeTimelockExpiration`,
///     `protocolFeeReceiver`, `ProtocolFeeReceiverPublicPath`,
///     `AdminStoragePath`, `DelegatorStoragePath`, `WithdrawPoolStoragePath`)
///   - The fee-queue / activate / setter surface on `Admin`
///     (`registerDelegator`, `setProtocolFee`, `activateProtocolFee`,
///     `setStakingPaused`, `setMinOperationAmount`, `setProtocolFeeReceiver`,
///     `setUnstakeUnlockEpochDelay`)
///
/// EVM mirror calls (`EVMRoute.setProtocolFee`, `setStakingPaused`,
/// `setMinRequestAmount`, `setSlippageTolerance`) and the EVM getters
/// (`lspVaultEVMAddress`, `governanceCoaEVMAddress`) are explicitly **dropped**
/// because the test runtime doesn't provision an `LSPVault` on the EVM side.
/// All other behavior (events, preconditions, timelock window) matches the
/// real contract one-for-one.
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

    access(all) event ProtocolFeeUpdateQueued(newFee: UFix64)
    access(all) event ProtocolFeeUpdated(oldFee: UFix64, newFee: UFix64)
    access(all) event ProtocolFeeReceiverUpdated(oldReceiver: Address, newReceiver: Address)
    access(all) event StakingPauseUpdated(paused: Bool)
    access(all) event MinStakeUpdated(oldMin: UFix64, newMin: UFix64)
    access(all) event UnstakeUnlockEpochDelayUpdated(oldDelayEpochs: UInt64, newDelayEpochs: UInt64)

    access(all) resource Admin {

        access(all) fun registerDelegator(nodeID: String, from: @FlowToken.Vault) {
            let delegator <- FlowIDTableStaking.registerNewDelegator(
                nodeID: nodeID,
                tokensCommitted: <-from
            )
            LiquidStakingConfig.account.storage.save(
                <-delegator,
                to: LiquidStakingConfig.DelegatorStoragePath
            )
        }

        access(all) fun setProtocolFee(newFee: UFix64) {
            pre { newFee <= 0.2: "Fee cannot exceed 20%" }
            LiquidStakingConfig.protocolFeePercentQueued = newFee
            LiquidStakingConfig.protocolFeeTimelockExpiration =
                UInt64(getCurrentBlock().timestamp) + LiquidStakingConfig.protocolFeeTimelockDuration
            emit ProtocolFeeUpdateQueued(newFee: newFee)
        }

        access(all) fun activateProtocolFee() {
            pre {
                UInt64(getCurrentBlock().timestamp) >= LiquidStakingConfig.protocolFeeTimelockExpiration:
                    "Fee timelock not expired"
            }
            let newFee = LiquidStakingConfig.protocolFeePercentQueued ?? panic("No fee update queued")
            let oldFee = LiquidStakingConfig.protocolFeePercent
            LiquidStakingConfig.protocolFeePercent = newFee
            LiquidStakingConfig.protocolFeePercentQueued = nil
            emit ProtocolFeeUpdated(oldFee: oldFee, newFee: newFee)
        }

        access(all) fun setStakingPaused(paused: Bool) {
            LiquidStakingConfig.isStakingPaused = paused
            emit StakingPauseUpdated(paused: paused)
        }

        access(all) fun setMinOperationAmount(newMin: UFix64) {
            pre { newMin > 0.0: "Minimum operation amount must be greater than 0" }
            let old = LiquidStakingConfig.minOperationAmount
            LiquidStakingConfig.minOperationAmount = newMin
            emit MinStakeUpdated(oldMin: old, newMin: newMin)
        }

        access(all) fun setProtocolFeeReceiver(newReceiver: Address) {
            pre {
                newReceiver != Address(0x0): "Protocol fee receiver cannot be the zero address"
                getAccount(newReceiver)
                    .capabilities
                    .borrow<&{FungibleToken.Receiver}>(LiquidStakingConfig.ProtocolFeeReceiverPublicPath) != nil:
                    "New receiver does not publish a FLOW receiver capability"
            }
            let old = LiquidStakingConfig.protocolFeeReceiver
            LiquidStakingConfig.protocolFeeReceiver = newReceiver
            emit ProtocolFeeReceiverUpdated(oldReceiver: old, newReceiver: newReceiver)
        }

        access(all) fun setUnstakeUnlockEpochDelay(newDelay: UInt64) {
            pre { newDelay <= 2: "Delay exceeds 2 epochs" }
            let old = LiquidStakingConfig.unstakeUnlockEpochDelay
            LiquidStakingConfig.unstakeUnlockEpochDelay = newDelay
            emit UnstakeUnlockEpochDelayUpdated(oldDelayEpochs: old, newDelayEpochs: newDelay)
        }
    }

    init(
        protocolFeePercent: UFix64,
        protocolFeeReceiver: Address,
        minOperationAmount: UFix64,
        unstakeUnlockEpochDelay: UInt64,
    ) {
        pre {
            protocolFeePercent <= 0.2: "Fee cannot exceed 20%"
            protocolFeeReceiver != Address(0x0): "Protocol fee receiver cannot be the zero address"
            minOperationAmount > 0.0: "Minimum operation amount must be greater than 0"
            unstakeUnlockEpochDelay <= 2: "Delay exceeds 2 epochs"
        }
        self.protocolFeeReceiver = protocolFeeReceiver
        self.ProtocolFeeReceiverPublicPath = /public/flowTokenReceiver
        self.protocolFeePercent = protocolFeePercent
        self.protocolFeePercentQueued = nil
        self.protocolFeeTimelockDuration = 604800
        self.protocolFeeTimelockExpiration = 0
        self.isStakingPaused = false
        self.minOperationAmount = minOperationAmount
        self.unstakeUnlockEpochDelay = unstakeUnlockEpochDelay
        self.AdminStoragePath = /storage/liquidStakingAdmin
        self.DelegatorStoragePath = /storage/liquidStakingDelegator
        self.WithdrawPoolStoragePath = /storage/liquidStakingWithdrawPool

        self.account.storage.save(<-create Admin(), to: self.AdminStoragePath)
    }
}
