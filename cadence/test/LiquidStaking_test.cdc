import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// Epoch-flip + reward-compound + unstake-withdraw lifecycle tests for
/// `cadence/contracts/LiquidStaking.cdc`.
///
/// Uses the mocked `FlowEpoch` + `FlowIDTableStaking` (`cadence/test/mocks/`) so
/// epoch counter, staking-enabled flag, reward accrual, and the unstaking-bucket
/// maturation can be driven deterministically from `flow test`. The protocol's
/// own `LiquidStakingConfig` is the test stub (no EVM mirror calls).
///
/// All tests run sequentially against shared blockchain state. They are
/// ordered so each precondition / assertion still holds when the file is run
/// end-to-end via `flow test cadence/test/LiquidStaking_test.cdc`.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userAccount: Test.TestAccount = Test.createAccount()

access(all) let mockNodeID: String = "lsp-mock-node"
access(all) let initialUserFlow: UFix64 = 10_000.0

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    setupFlowVault(userAccount)
    setupSFlowVault(userAccount)
    let mintResult = mintFlow(to: userAccount, amount: initialUserFlow)
    Test.expect(mintResult, Test.beSucceeded())
    setupSFlowVault(protocolAccount)
    registerProtocolDelegator()
    seedRewardPool(amount: 5_000.0)
}

// ---- 1. initial state ----

access(all)
fun testInitialState() {
    Test.assertEqual(/storage/liquid_staking_flow_receipt_collection, LiquidStaking.FlowReceiptCollectionPath)
    Test.assertEqual(/public/liquid_staking_flow_receipt_collection, LiquidStaking.FlowReceiptCollectionPublicPath)
    Test.assertEqual(0 as UInt64, readEpochCounter())
    Test.assertEqual(true, readStakingEnabled())
    Test.assertEqual(0.0, readTotalFlowStaked())
    Test.assertEqual(0.0, readSFlowTotalSupply())
    Test.assertEqual(1.0, readFlowPerSFlow())
    Test.assertEqual(1.0, readSFlowPerFlow())
}

access(all)
fun testCalcFlowFromSFlowPanicsWithNoBacking() {
    let result = Test.executeScript(
        "import \"LiquidStaking\"\n"
            .concat("access(all) fun main(): UFix64 {\n")
            .concat("    return LiquidStaking.calcFlowFromSFlow(sFlowAmount: 10.0)\n")
            .concat("}\n"),
        []
    )
    Test.assert(result.error != nil, message: "expected calcFlowFromSFlow to panic with no FLOW backing")
}

access(all)
fun testCalcSFlowFromFlowOneToOneWhenPoolEmpty() {
    Test.assertEqual(50.0, readCalcSFlowFromFlow(50.0))
    Test.assertEqual(1.0, readFlowPerSFlow())
}

access(all)
fun testCompoundRewardsRevertsWithZeroSupply() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/compound_rewards.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [],
    ))
    Test.expect(txResult, Test.beFailed())
    Test.assert(txResult.error != nil, message: "expected compound to fail with zero sFlow supply")
}

// ---- 2. stake happy path ----

access(all)
fun testStakeMintsSFlowOneToOneWhenPoolEmpty() {
    let stakeAmount: UFix64 = 100.0
    let supplyBefore = readSFlowTotalSupply()
    let stakedBefore = readTotalFlowStaked()
    let userSFlowBefore = readSFlowBalance(userAccount.address)

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [stakeAmount],
    ))
    Test.expect(txResult, Test.beSucceeded())

    Test.assertEqual(supplyBefore + stakeAmount, readSFlowTotalSupply())
    Test.assertEqual(stakedBefore + stakeAmount, readTotalFlowStaked())
    Test.assertEqual(userSFlowBefore + stakeAmount, readSFlowBalance(userAccount.address))

    let staked = Test.eventsOfType(Type<LiquidStaking.Staked>())
    Test.assert(staked.length >= 1, message: "expected Staked event")
    let last = staked[staked.length - 1] as! LiquidStaking.Staked
    Test.assertEqual(stakeAmount, last.flowAmount)
    Test.assertEqual(stakeAmount, last.sFlowAmount)
}

// ---- 3. stake gating ----

access(all)
fun testStakeRevertsWhenPaused() {
    setStakingPaused(true)
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [50.0],
    ))
    Test.expect(txResult, Test.beFailed())
    setStakingPaused(false)
}

access(all)
fun testStakeRevertsWhenStakingDisabled() {
    setStakingEnabled(false)
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [50.0],
    ))
    Test.expect(txResult, Test.beFailed())
    setStakingEnabled(true)
}

access(all)
fun testStakeRevertsBelowMinOperationAmount() {
    let belowMin: UFix64 = 0.99999999
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [belowMin],
    ))
    Test.expect(txResult, Test.beFailed())
    Test.assert(
        errorIncludes(txResult.error?.message, substring: "0.99999999"),
        message: "stake precondition should include attempted amount"
    )
    Test.assert(
        errorIncludes(txResult.error?.message, substring: "1.00000000"),
        message: "stake precondition should include configured minimum"
    )
}

access(all)
fun testStakeAtMinOperationAmountSucceeds() {
    let minAmount: UFix64 = 1.0
    let sFlowBefore = readSFlowBalance(userAccount.address)
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [minAmount],
    ))
    Test.expect(txResult, Test.beSucceeded())
    Test.assertEqual(sFlowBefore + minAmount, readSFlowBalance(userAccount.address))
}

access(all)
fun testUnstakeRevertsBelowMinOperationAmount() {
    let belowMin: UFix64 = 0.99999999
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_unstake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [belowMin],
    ))
    Test.expect(txResult, Test.beFailed())
    Test.assert(
        errorIncludes(txResult.error?.message, substring: "0.99999999"),
        message: "unstake precondition should include attempted amount"
    )
}

// ---- 4. compound rewards ----

access(all)
fun testCompoundRewardsTakesFeeAndCompoundsRest() {
    let rewardAmount: UFix64 = 50.0
    accrueRewards(amount: rewardAmount)

    let stakedBefore = readTotalFlowStaked()
    let supplyBefore = readSFlowTotalSupply()
    let treasuryBefore = readFlowBalance(protocolAddress)
    let ratioBefore = readFlowPerSFlow()

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/compound_rewards.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [],
    ))
    Test.expect(txResult, Test.beSucceeded())

    let feeExpected: UFix64 = rewardAmount * 0.1
    let restakeExpected: UFix64 = rewardAmount - feeExpected

    Test.assertEqual(stakedBefore + restakeExpected, readTotalFlowStaked())
    Test.assertEqual(supplyBefore, readSFlowTotalSupply())
    Test.assertEqual(treasuryBefore + feeExpected, readFlowBalance(protocolAddress))
    Test.assert(readFlowPerSFlow() > ratioBefore, message: "flowPerSFlow must strictly increase after compound")

    let compounded = Test.eventsOfType(Type<LiquidStaking.RewardsCompounded>())
    let lastEv = compounded[compounded.length - 1] as! LiquidStaking.RewardsCompounded
    Test.assertEqual(rewardAmount, lastEv.rewardAmount)
    Test.assertEqual(feeExpected, lastEv.feeAmount)
}

access(all)
fun testExchangeMathMintsLessSFlowAfterCompound() {
    let flowIn: UFix64 = 10.0
    let sFlowMinted = readCalcSFlowFromFlow(flowIn)
    Test.assert(sFlowMinted < flowIn, message: "after compound, minting should require fewer sFlow per FLOW")
    let flowOut = readCalcFlowFromSFlow(sFlowMinted)
    Test.assert(flowOut <= flowIn, message: "single-division redeem must not exceed deposited FLOW")
}

// ---- 5. unstake + receipt accounting ----

access(all)
fun testUnstakeProducesReceiptWithCorrectUnlockEpoch() {
    let unstakeSFlow: UFix64 = 25.0
    let expectedFlow = readCalcFlowFromSFlow(unstakeSFlow)

    let stakedBefore = readTotalFlowStaked()
    let supplyBefore = readSFlowTotalSupply()
    let epochBefore = readEpochCounter()

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_unstake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [unstakeSFlow],
    ))
    Test.expect(txResult, Test.beSucceeded())

    Test.assertEqual(stakedBefore - expectedFlow, readTotalFlowStaked())
    Test.assertEqual(supplyBefore - unstakeSFlow, readSFlowTotalSupply())

    let unstakeEvents = Test.eventsOfType(Type<LiquidStaking.UnstakeRequested>())
    Test.assert(unstakeEvents.length >= 1, message: "expected UnstakeRequested event")
    let last = unstakeEvents[unstakeEvents.length - 1] as! LiquidStaking.UnstakeRequested
    Test.assertEqual(epochBefore + 2 as UInt64, last.unlockEpoch)
    Test.assertEqual(unstakeSFlow, last.sFlowAmount)
    Test.assertEqual(expectedFlow, last.flowAmount)

    let receipts = readReceipts(userAccount.address)
    Test.assertEqual(1, receipts.length)

    let deposited = Test.eventsOfType(Type<LiquidStaking.FlowReceiptDeposited>())
    Test.assert(deposited.length >= 1, message: "expected FlowReceiptDeposited event")
    let depositEvent = deposited[deposited.length - 1] as! LiquidStaking.FlowReceiptDeposited
    Test.assertEqual(last.id, depositEvent.id)
    Test.assertEqual(expectedFlow, depositEvent.flowAmount)
    Test.assertEqual(epochBefore + 2 as UInt64, depositEvent.unlockEpoch)
    Test.assertEqual(userAccount.address, depositEvent.owner!)
}

// ---- 6. withdraw is blocked before the unlock epoch ----

access(all)
fun testWithdrawBlockedBeforeUnlock() {
    let uuid = receiptUuidAt(userAccount.address, index: 0)
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(txResult, Test.beFailed())
    Test.assert(
        errorIncludes(txResult.error?.message, substring: "Unstake not unlocked"),
        message: "withdraw precondition should describe unlock failure"
    )
}

access(all)
fun testWithdrawFailsForUnknownReceiptUuid() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [999_999 as UInt64],
    ))
    Test.expect(txResult, Test.beFailed())
    Test.assert(
        errorIncludes(txResult.error?.message, substring: "999999"),
        message: "missing receipt withdraw should include uuid"
    )
}

// ---- 7. withdraw succeeds after epoch advance + matureUnstaking ----

access(all)
fun testWithdrawSucceedsAfterEpochAdvance() {
    let uuid = receiptUuidAt(userAccount.address, index: 0)
    let receiptFlow = receiptAmountAt(userAccount.address, index: 0)
    let userFlowBefore = readFlowBalance(userAccount.address)

    advanceEpoch(2)

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(txResult, Test.beSucceeded())

    Test.assertEqual(userFlowBefore + receiptFlow, readFlowBalance(userAccount.address))
    Test.assertEqual(0, readReceipts(userAccount.address).length)

    let retry = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(retry, Test.beFailed())

    let fulfilled = Test.eventsOfType(Type<LiquidStaking.UnstakeFulfilled>())
    let last = fulfilled[fulfilled.length - 1] as! LiquidStaking.UnstakeFulfilled
    Test.assertEqual(uuid, last.id)
    Test.assertEqual(receiptFlow, last.flowAmount)

    let withdrawn = Test.eventsOfType(Type<LiquidStaking.FlowReceiptWithdrawn>())
    Test.assert(withdrawn.length >= 1, message: "expected FlowReceiptWithdrawn event")
    let withdrawEvent = withdrawn[withdrawn.length - 1] as! LiquidStaking.FlowReceiptWithdrawn
    Test.assertEqual(uuid, withdrawEvent.id)
    Test.assertEqual(receiptFlow, withdrawEvent.flowAmount)
    Test.assertEqual(userAccount.address, withdrawEvent.owner!)
}

// ---- 8. unstakeUnlockEpochDelay admin override ----

access(all)
fun testUnstakeUnlockEpochDelayOverride() {
    setUnstakeDelay(1)

    let unstakeSFlow: UFix64 = 5.0
    let unstakeTx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_unstake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [unstakeSFlow],
    ))
    Test.expect(unstakeTx, Test.beSucceeded())

    let uuid = receiptUuidAt(userAccount.address, index: 0)

    advanceEpoch(2)
    // unlockEpoch == createdEpoch + 2 ; effective unlock = unlockEpoch + delay (1).
    // After advancing by 2 we are at unlockEpoch (not yet unlockEpoch + 1) → still locked.
    let stillLocked = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(stillLocked, Test.beFailed())

    advanceEpoch(1)
    let unlocked = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(unlocked, Test.beSucceeded())

    setUnstakeDelay(0)
}

access(all)
fun testWithdrawStuckReceiptIgnoresAdminDelay() {
    setUnstakeDelay(1)

    let unstakeSFlow: UFix64 = 5.0
    let unstakeTx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_unstake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [unstakeSFlow],
    ))
    Test.expect(unstakeTx, Test.beSucceeded())

    let uuid = receiptUuidAt(userAccount.address, index: 0)

    advanceEpoch(2)

    let normalWithdraw = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(normalWithdraw, Test.beFailed())

    let stuckWithdraw = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw_stuck.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(stuckWithdraw, Test.beSucceeded())

    setUnstakeDelay(0)
}

// =========================================================================
// helpers
// =========================================================================

access(all)
fun deployAll() {
    var err = Test.deployContract(
        name: "FlowEpoch",
        path: "../../cadence/test/mocks/FlowEpoch.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowIDTableStaking",
        path: "../../cadence/test/mocks/FlowIDTableStaking.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "sFlowToken",
        path: "../../cadence/contracts/sFlowToken.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "EVMRoute",
        path: "../../cadence/contracts/EVMRoute.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "LiquidStakingConfig",
        path: "../../cadence/test/fixtures/LiquidStakingConfigStub.cdc",
        arguments: [0.1, protocolAddress, 1.0, 0 as UInt64],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "LiquidStaking",
        path: "../../cadence/contracts/LiquidStaking.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "LiquidStakingTestKit",
        path: "../../cadence/test/fixtures/LiquidStakingTestKit.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())
}

access(all)
fun fundProtocol() {
    setupFlowVault(protocolAccount)
    let r = mintFlow(to: protocolAccount, amount: 100_000.0)
    Test.expect(r, Test.beSucceeded())
}

access(all)
fun setupFlowVault(_ acct: Test.TestAccount) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/setup_flow_token_vault.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun setupSFlowVault(_ acct: Test.TestAccount) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/setup_sflow_vault.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun registerProtocolDelegator() {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/register_protocol_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [mockNodeID, 100.0],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun seedRewardPool(amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/seed_staking_reward_pool.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun setStakingPaused(_ paused: Bool) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_staking_paused.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [paused],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun setStakingEnabled(_ enabled: Bool) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_staking_enabled.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [enabled],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun setUnstakeDelay(_ n: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_unstake_delay.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [n],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun accrueRewards(amount: UFix64) {
    // delegator IDs start at 1 in our mock; the protocol always gets ID=1
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/accrue_rewards.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [mockNodeID, 1 as UInt32, amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun advanceEpoch(_ n: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/advance_epoch.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [n],
    ))
    Test.expect(tx, Test.beSucceeded())
}

// ---- read-only helpers (always via script so we get fresh contract state) ----

access(all)
fun readEpochCounter(): UInt64 {
    let r = Test.executeScript(
        "import \"FlowEpoch\"\naccess(all) fun main(): UInt64 { return FlowEpoch.currentEpochCounter }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UInt64
}

access(all)
fun readStakingEnabled(): Bool {
    let r = Test.executeScript(
        "import \"FlowIDTableStaking\"\naccess(all) fun main(): Bool { return FlowIDTableStaking.stakingEnabled() }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! Bool
}

access(all)
fun readTotalFlowStaked(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.totalFlowStaked }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readSFlowTotalSupply(): UFix64 {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_sflow_total_supply.cdc"),
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readFlowPerSFlow(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.flowPerSFlow() }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readSFlowPerFlow(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.sFlowPerFlow() }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readCalcFlowFromSFlow(_ amount: UFix64): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(amt: UFix64): UFix64 { return LiquidStaking.calcFlowFromSFlow(sFlowAmount: amt) }\n",
        [amount]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readCalcSFlowFromFlow(_ amount: UFix64): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(amt: UFix64): UFix64 { return LiquidStaking.calcSFlowFromFlow(flowAmount: amt) }\n",
        [amount]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun errorIncludes(_ error: String?, substring: String): Bool {
    if error == nil {
        return false
    }
    return error!.index(of: substring) != nil
}

access(all)
fun readFlowBalance(_ addr: Address): UFix64 {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_flow_balance.cdc"),
        [addr]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readSFlowBalance(_ addr: Address): UFix64 {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_sflow_balance.cdc"),
        [addr]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readReceipts(_ addr: Address): [AnyStruct] {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_receipts.cdc"),
        [addr]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! [AnyStruct]
}

access(all)
fun receiptUuidAt(_ addr: Address, index: Int): UInt64 {
    let receipts = readReceipts(addr)
    let info = receipts[index] as! {String: AnyStruct}
    return info["uuid"]! as! UInt64
}

access(all)
fun receiptAmountAt(_ addr: Address, index: Int): UFix64 {
    let receipts = readReceipts(addr)
    let info = receipts[index] as! {String: AnyStruct}
    return info["flowAmount"]! as! UFix64
}
