import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// DelegatorSet tests: lifecycle-aware redemption + multi-slot rotation.
/// Uses the same stub Config + staking mocks as `LiquidStaking_test.cdc`.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userAccount: Test.TestAccount = Test.createAccount()

access(all) let nodeA: String = "lsp-node-a"
access(all) let nodeB: String = "lsp-node-b"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    setupFlowVault(userAccount)
    setupSFlowVault(userAccount)
    let mintResult = mintFlow(to: userAccount, amount: 10_000.0)
    Test.expect(mintResult, Test.beSucceeded())
    setupSFlowVault(protocolAccount)
    registerDelegator(nodeA, 50.0)
    seedProtocolOwnedSFlow()
    seedRewardPool(amount: 1_000.0)
}

access(all)
fun testDelegatorSetCreatedOnFirstRegister() {
    let summary = readSetSummary()
    Test.assertEqual(1, summary["slotCount"]! as! Int)
    Test.assertEqual(0 as UInt64, summary["depositTarget"]! as! UInt64)
    Test.assertEqual(0.0, summary["pending"]! as! UFix64)

    let flat = readSlotsFlat()
    // slot0: id=0, status=Active(0), pending=0, committed=0, staked=51 (50 register + 1 seed), ...
    Test.assertEqual(0.0, flat[0])
    Test.assertEqual(0.0, flat[1])
    Test.assertEqual(0.0, flat[2])
    Test.assertEqual(51.0, flat[4])
}

access(all)
fun testNormalUnstakeUsesNewRequestAndPendingClaims() {
    stake(100.0)
    let pendingBefore = readPendingWithdrawal()
    unstake(40.0)
    Test.assertEqual(pendingBefore + 40.0, readPendingWithdrawal())

    let flat = readSlotsFlat()
    Test.assertEqual(40.0, flat[2]) // pendingClaims on slot 0
    // mock moves request straight into unstaking
    Test.assertEqual(40.0, flat[5]) // tokensUnstaking
}

access(all)
fun testNormalUnstakeWithdrawAfterMaturityClearsPending() {
    // Continues from prior test state: 40 pending on slot 0
    advanceEpoch(2)
    let flowBefore = readFlowBalance(userAccount.address)
    let uuid = receiptUuidAt(userAccount.address, index: 0)
    withdraw(uuid)
    Test.assertEqual(flowBefore + 40.0, readFlowBalance(userAccount.address))
    Test.assertEqual(0.0, readPendingWithdrawal())
}

access(all)
fun testNodeExitThenUnstakeAllocatesExitingWithoutNewRequest() {
    // Stake more on slot 0, then force-exit the Flow delegator.
    stake(200.0)
    let flowDelId = readSlotFlowDelegatorId(0)
    forceExit(nodeA, flowDelId)

    let flatAfterExit = readSlotsFlat()
    // All stake should be in unstaking; pendingClaims still 0 (exit bypassed protocol)
    Test.assertEqual(0.0, flatAfterExit[2])
    Test.assert(flatAfterExit[5] > 0.0, message: "expected unstaking > 0 after force exit")
    Test.assertEqual(0.0, flatAfterExit[4]) // staked emptied

    let pendingBefore = readPendingWithdrawal()
    let sFlowBefore = readSFlowBalance(userAccount.address)
    unstake(50.0)

    Test.assertEqual(sFlowBefore - 50.0, readSFlowBalance(userAccount.address))
    Test.assertEqual(pendingBefore + 50.0, readPendingWithdrawal())

    // Unstaking bucket should be unchanged by allocate-from-exiting (no new request)
    let flatAfterUnstake = readSlotsFlat()
    Test.assertEqual(flatAfterExit[5], flatAfterUnstake[5])
    Test.assertEqual(50.0, flatAfterUnstake[2])

    // Receipt unlock should be current+1 (from unstaking), not +2
    let receipts = readReceipts(userAccount.address)
    let last = receipts[receipts.length - 1] as! {String: AnyStruct}
    let unlock = last["unlockEpoch"]! as! UInt64
    Test.assertEqual(readEpochCounter() + 1, unlock)
}

access(all)
fun testSecondDelegatorReceivesNewStakesAfterRotation() {
    // Mark slot 0 draining, add slot 1 on node B, set deposit target.
    markDraining(0)
    registerDelegator(nodeB, 10.0)
    setDepositTarget(1)

    let summary = readSetSummary()
    Test.assertEqual(2, summary["slotCount"]! as! Int)
    Test.assertEqual(1 as UInt64, summary["depositTarget"]! as! UInt64)

    let slot1Before = readSlot(1)
    let slot0StakedBefore = readSlot(0)[3]
    stake(30.0)
    let slot1After = readSlot(1)
    Test.assertEqual(slot1Before[3] + 30.0, slot1After[3])
    Test.assertEqual(slot0StakedBefore, readSlot(0)[3])
}

access(all)
fun testUnstakePrefersDrainingExitingOverActiveNewRequest() {
    // Slot 0 is draining with exiting (from earlier force-exit + residual).
    // Unstake should consume draining exiting first.
    let slot0Before = readSlot(0)
    let slot1Before = readSlot(1)
    let slot0PendingBefore = slot0Before[1]
    let slot0UnstakingBefore = slot0Before[4]
    let slot1StakedBefore = slot1Before[3]

    let redeem = 20.0
    unstake(redeem)

    let slot0After = readSlot(0)
    let slot1After = readSlot(1)
    Test.assertEqual(slot0PendingBefore + redeem, slot0After[1])
    // Active slot 1 should not lose free stake if slot0 exiting covered the redeem
    if slot0UnstakingBefore - slot0PendingBefore >= redeem {
        Test.assertEqual(slot1StakedBefore, slot1After[3])
        Test.assertEqual(0.0, slot1After[1])
    }
}

access(all)
fun testUnstakeAllocatesFromEarliestExitingEpochFirst() {
    // SFL-06: within the draining group, allocation must order slots by earliest
    // unlock epoch (not dictionary key order). Register two fresh draining slots
    // whose slot IDs are the opposite of maturity order: slot 3 has unstaked
    // (current-epoch) capacity while slot 2 has only unstaking (next-epoch).
    registerDelegator(nodeA, 100.0)
    registerDelegator(nodeB, 100.0)
    markDraining(2)
    markDraining(3)

    let slot2FlowDelId = readSlotFlowDelegatorId(2)
    let slot3FlowDelId = readSlotFlowDelegatorId(3)

    // Both new slots become exiting (unstaking buckets).
    forceExit(nodeA, slot2FlowDelId)
    forceExit(nodeB, slot3FlowDelId)

    // Mature only slot 3 so it has unstaked (current-epoch) capacity.
    matureUnstakingAmount(nodeB, slot3FlowDelId, 100.0)

    let slot0Before = readSlot(0)
    let slot2Before = readSlot(2)
    let slot3Before = readSlot(3)

    // Unstake an amount fully coverable by slot 3's earliest-epoch capacity.
    unstake(10.0)

    let slot0After = readSlot(0)
    let slot2After = readSlot(2)
    let slot3After = readSlot(3)

    // Slot 3 (earliest epoch) should have taken the claim; earlier-ID draining
    // slots should be untouched.
    Test.assertEqual(slot3Before[1] + 10.0, slot3After[1])
    Test.assertEqual(slot2Before[1], slot2After[1])
    Test.assertEqual(slot0Before[1], slot0After[1])
}

// ---- helpers ----

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
fun registerDelegator(_ nodeID: String, _ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/register_protocol_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, amount],
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
fun seedProtocolOwnedSFlow() {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/seed_protocol_owned_sflow.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun stake(_ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun unstake(_ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_unstake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun withdraw(_ uuid: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [uuid],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun matureUnstakingAmount(_ nodeID: String, _ delegatorID: UInt32, _ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/mature_unstaking_amount.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, delegatorID, amount],
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

access(all)
fun forceExit(_ nodeID: String, _ delegatorID: UInt32) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/force_exit_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, delegatorID],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun markDraining(_ slotId: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/mark_delegator_draining.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [slotId],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun setDepositTarget(_ slotId: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_deposit_target.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [slotId],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun readSetSummary(): {String: AnyStruct} {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_delegator_set_summary.cdc"),
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! {String: AnyStruct}
}

access(all)
fun readSlotsFlat(): [UFix64] {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_slot_snapshots_flat.cdc"),
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! [UFix64]
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
fun readSlot(_ slotId: UInt64): [UFix64] {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_slot_by_id.cdc"),
        [slotId]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! [UFix64]
}

access(all)
fun readPendingWithdrawal(): UFix64 {
    let summary = readSetSummary()
    return summary["pending"]! as! UFix64
}

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
fun readSlotFlowDelegatorId(_ slotId: UInt64): UInt32 {
    let r = Test.executeScript(
        "import \"LiquidStakingConfig\"\n"
            .concat("access(all) fun main(slotId: UInt64): UInt32 {\n")
            .concat("    let snaps = LiquidStakingConfig.getSlotSnapshots()\n")
            .concat("    var i = 0\n")
            .concat("    while i < snaps.length {\n")
            .concat("        if snaps[i].slotId == slotId {\n")
            .concat("            return snaps[i].flowDelegatorId\n")
            .concat("        }\n")
            .concat("        i = i + 1\n")
            .concat("    }\n")
            .concat("    panic(\"slot not found\")\n")
            .concat("}\n"),
        [slotId]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UInt32
}

access(all)
fun receiptUuidAt(_ addr: Address, index: Int): UInt64 {
    let receipts = readReceipts(addr)
    let info = receipts[index] as! {String: AnyStruct}
    return info["uuid"]! as! UInt64
}
