import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"
import "LiquidStakingTestKit"

/// `LiquidStaking.reconcileRecoveredShortfall()` must only restore
/// `unclassifiedShortfall` to `totalFlowStaked` up to the amount verified by
/// `actualDelegatorBacking()` -- it must never recreate the original phantom-backing bug by
/// allowing the admin to restore more than is actually present.
///
/// Isolated (fresh-chain) test, following the same pattern as
/// `LiquidStaking_reward_rounding_test.cdc` / `LiquidStaking_settlement_fairness_test.cdc`.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userAccount: Test.TestAccount = Test.createAccount()

access(all) let mockNodeID: String = "lsp-shortfall-node"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    // Zero-amount registration avoids funding the staked bucket outside
    // totalFlowStaked tracking, so actualDelegatorBacking() stays exactly in sync with
    // totalFlowStaked for a clean bound-check scenario below.
    registerProtocolDelegator(nodeID: mockNodeID, amount: 0.0)
    seedProtocolOwnedSFlow()

    setupFlowVault(userAccount)
    setupSFlowVault(userAccount)
    Test.expect(mintFlow(to: userAccount, amount: 1_000.0), Test.beSucceeded())
}

access(all)
fun testReconcileRecoveredShortfallRestoresUpToVerifiedBackingThenRejectsExcess() {
    stake(userAccount, 100.0)
    let uuid = unstakeAndGetReceiptUuid(userAccount, 50.0)
    let receiptFlow = 50.0

    // Only part of the unstaking bucket matures; withdrawStuckReceipt settles the receipt
    // but can't pay the full effective amount, recording the remainder as
    // unclassifiedShortfall instead of inflating totalFlowStaked.
    advanceEpochCounter(2)
    let withdrawAmount: UFix64 = 10.0
    matureUnstakingAmount(nodeID: mockNodeID, delegatorID: 1, amount: withdrawAmount)

    withdrawStuck(userAccount, uuid)

    let shortfall = receiptFlow - withdrawAmount
    Test.assertEqual(shortfall, readUnclassifiedShortfall())
    let totalAfterSettlement = readTotalFlowStaked()

    // Of the remaining 40.0 FLOW shortfall, only 20.0 turns out to still be recoverable
    // (matured into tokensUnstaked); the other 20.0 is permanently slashed away, so
    // actualDelegatorBacking() only has room to verify 20.0 of the 40.0 unclassified amount.
    let verifiable: UFix64 = 20.0
    let permanentlyLost = shortfall - verifiable
    matureUnstakingAmount(nodeID: mockNodeID, delegatorID: 1, amount: verifiable)
    slashDelegator(nodeID: mockNodeID, delegatorID: 1, amount: permanentlyLost)

    // Reconciling more than actualDelegatorBacking() can verify must revert, even though
    // the requested amount is still <= unclassifiedShortfall -- the bound against actual
    // backing, not just the shortfall counter, is what prevents recreating the original
    // phantom-backing bug.
    let overReconcile = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/transactions/admin/reconcile_recovered_shortfall.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [verifiable + 1.0],
    ))
    Test.expect(overReconcile, Test.beFailed())

    // Reconciling exactly the verified amount succeeds and restores it to totalFlowStaked.
    let reconcile = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/transactions/admin/reconcile_recovered_shortfall.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [verifiable],
    ))
    Test.expect(reconcile, Test.beSucceeded())

    Test.assertEqual(permanentlyLost, readUnclassifiedShortfall())
    Test.assertEqual(totalAfterSettlement + verifiable, readTotalFlowStaked())

    let reconciled = Test.eventsOfType(Type<LiquidStaking.ShortfallReconciled>())
    let last = reconciled[reconciled.length - 1] as! LiquidStaking.ShortfallReconciled
    Test.assertEqual(verifiable, last.amount)
    Test.assertEqual(permanentlyLost, last.unclassifiedShortfall)

    // The remaining permanently-lost portion is written off, not restored.
    let writeOff = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/transactions/admin/write_off_shortfall.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [permanentlyLost],
    ))
    Test.expect(writeOff, Test.beSucceeded())
    Test.assertEqual(0.0, readUnclassifiedShortfall())
    Test.assertEqual(totalAfterSettlement + verifiable, readTotalFlowStaked())
}

// ---- setup helpers ----

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

    err = Test.deployContract(
        name: "RelayerRouter",
        path: "../../cadence/test/fixtures/RelayerRouterStub.cdc",
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
fun registerProtocolDelegator(nodeID: String, amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/register_protocol_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, amount],
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
fun stake(_ acct: Test.TestAccount, _ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun unstakeAndGetReceiptUuid(_ acct: Test.TestAccount, _ sFlowAmount: UFix64): UInt64 {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_unstake.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [sFlowAmount],
    ))
    Test.expect(tx, Test.beSucceeded())

    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_receipts.cdc"),
        [acct.address]
    )
    Test.expect(r, Test.beSucceeded())
    let receipts = r.returnValue! as! [AnyStruct]
    let info = receipts[receipts.length - 1] as! {String: AnyStruct}
    return info["uuid"]! as! UInt64
}

access(all)
fun advanceEpochCounter(_ n: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/advance_epoch_counter.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [n],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun matureUnstakingAmount(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/mature_unstaking_amount.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, delegatorID, amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun slashDelegator(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/slash_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, delegatorID, amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun withdrawStuck(_ acct: Test.TestAccount, _ uuid: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw_stuck.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [uuid],
    ))
    Test.expect(tx, Test.beSucceeded())
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
fun readUnclassifiedShortfall(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.unclassifiedShortfall }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}
