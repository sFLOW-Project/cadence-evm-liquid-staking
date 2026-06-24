import "FlowToken"
import "FungibleToken"
import "FlowIDTableStaking"
import "EVM"
import "EVMRoute"

/// Governance-controlled protocol parameters and **`Admin`** for liquid staking.
/// Deploy on the **same account** as **`LiquidStaking`** so admin **`registerDelegator`** saves the
/// **`FlowIDTableStaking.NodeDelegator`** into protocol storage.
///
access(all) contract LiquidStakingConfig {

    /// Account that receives FLOW protocol fees (`LiquidStaking.compoundRewards`). Must publish `&{FungibleToken.Receiver}` at **`ProtocolFeeReceiverPublicPath`**.
    access(all) var protocolFeeReceiver: Address
    /// Public path for FLOW receiver on **`protocolFeeReceiver`** (conventional Flow setup).
    access(all) let ProtocolFeeReceiverPublicPath: PublicPath

    /// Duration of the protocol fee timelock.
    access(all) let protocolFeeTimelockDuration: UInt64
    /// Timestamp when the protocol fee timelock expires.
    access(all) var protocolFeeTimelockExpiration: UInt64
    /// Queued protocol fee update (`nil` if none).
    access(all) var protocolFeePercentQueued: UFix64?
    /// Protocol fee taken from each epoch's rewards (e.g. `0.1` = 10%).
    access(all) var protocolFeePercent: UFix64

    /// When true, **`LiquidStaking.stake`** is rejected (mirror EVM `isStakingPaused` via admin txs).
    access(all) var isStakingPaused: Bool
    /// Minimum FLOW per stake/unstake on Cadence (align with EVM `minRequestAmount` via admin sync tx).
    access(all) var minOperationAmount: UFix64

    /// Added to **`FlowEpoch.currentEpochCounter`** at unstake to set unlock epoch (admin; max 2).
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

        access(self) let coa: @EVM.CadenceOwnedAccount
        access(self) let vault: EVM.EVMAddress
        
        access(self) fun borrowCoa(): auth(EVM.Call, EVM.Withdraw, EVM.Bridge) &EVM.CadenceOwnedAccount {
            return (&self.coa)
        }

        init(coa: @EVM.CadenceOwnedAccount, vault: EVM.EVMAddress) {
            self.coa <- coa
            self.vault = vault
        }

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
            EVMRoute.setSlippageTolerance(
                coa: self.borrowCoa(),
                vault: self.vault,
                slippageTolerance: EVMRoute.tokenUFix64ToScaledUInt256(slippageTolerance)
            )
        }

        /// Used by **`setup_phase3.cdc`** (EVM snapshot / vault reads).
        access(all) fun lspVaultEVMAddress(): EVM.EVMAddress {
            return self.vault
        }

        /// COA held by **`Admin`** (EVM governance / LSP `Ownable`).
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

        self.account.storage.save(<-create Admin(coa: <-coa, vault: vault), to: self.AdminStoragePath)
    }

    /// Used by **`setup_phase3.cdc`** for vault / COA snapshot fields.
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
