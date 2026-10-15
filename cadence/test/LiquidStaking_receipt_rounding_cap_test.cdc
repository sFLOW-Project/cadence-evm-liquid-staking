import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// `LiquidStaking.effectiveReceiptAmount()` derives each receipt's entitlement from
/// `outstandingLossFactor` (a cumulative product updated once per `realizeLoss()` call),
/// while `totalFlowReceiptsOutstanding` is shrunk independently, pro-rata, in that same
/// call. Both are UFix64 values rounded on the 1e-8 grid, and after two or more realized
/// losses the two independently-rounded quantities can drift apart by a dust amount: a
/// receipt's computed `effective` entitlement can end up fractionally larger than what
/// `totalFlowReceiptsOutstanding` actually has reserved for it.
///
/// Without a cap, settling every outstanding receipt at its raw (uncapped) `effective`
/// amount can therefore pay out slightly more than was ever reserved in
/// `totalFlowReceiptsOutstanding`, with the excess silently drawn from FLOW that is
/// supposed to back sFLOW (`totalFlowStaked` is never adjusted downward to compensate).
/// `effectiveReceiptAmount()` must cap each settlement at the remaining recorded
/// `totalFlowReceiptsOutstanding` so that settled amounts can never sum to more than it,
/// regardless of per-receipt rounding drift -- this is an invariant that must hold
/// independent of settlement order.
///
/// Isolated (fresh-chain) test, following the same pattern as
/// `LiquidStaking_shortfall_reconciliation_test.cdc` / `LiquidStaking_settlement_fairness_test.cdc`.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userA: Test.TestAccount = Test.createAccount()
access(all) let userB: Test.TestAccount = Test.createAccount()

access(all) let mockNodeID: String = "lsp-rounding-cap-node"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    // Fund the slot's staked bucket well beyond totalFlowStaked tracking so there is
    // plenty of headroom to slash against without physically starving the "unstaking" /
    // "unstaked" buckets the two receipts below will settle from -- this isolates the
    // rounding-drift behavior from the (separately tested) physical-shortfall/pro-rata
    // haircut behavior.
    registerProtocolDelegator(nodeID: mockNodeID, amount: 100_000.0)
    seedProtocolOwnedSFlow()

    setupFlowVault(userA)
    setupSFlowVault(userA)
    Test.expect(mintFlow(to: userA, amount: 1_000.0), Test.beSucceeded())

    setupFlowVault(userB)
    setupSFlowVault(userB)
    Test.expect(mintFlow(to: userB, amount: 1_000.0), Test.beSucceeded())
}

access(all)
fun testSuccessiveLossRoundingNeverExceedsRecordedOutstanding() {
    // Two equal-sized receipts created before any loss (lossFactorAtCreation == 0.0 for
    // both), so both receipts' entitlement tracks the global outstandingLossFactor
    // identically -- the simplest setting in which independent rounding of
    // outstandingLossFactor vs. totalFlowReceiptsOutstanding can drift apart.
    stake(userA, 100.0)
    let uuidA = unstakeAndGetReceiptUuid(userA, 100.0)

    stake(userB, 100.0)
    let uuidB = unstakeAndGetReceiptUuid(userB, 100.0)

    let outstandingBefore = readTotalFlowReceiptsOutstanding()
    Test.assertEqual(200.0, outstandingBefore)

    // Slash the slot's *staked* bucket (not the unstaking/unstaked buckets the two
    // receipts above already moved into) so the two realizeLoss() calls below are backed
    // by a genuine, verifiable shortfall, without touching the liquidity the receipts will
    // settle from.
    slashDelegator(nodeID: mockNodeID, delegatorID: 1, amount: 100_000.1)
    let maxLoss = readMaxRealizableLoss()
    Test.assert(maxLoss > 0.0, message: "setup must produce a positive verifiable shortfall")

    // Two successive losses with "ugly" ratios (non-terminating on the UFix64 1e-8 grid)
    // against the combined basis, so outstandingLossFactor's compounded-product rounding
    // and totalFlowReceiptsOutstanding's independent pro-rata rounding have the chance to
    // diverge.
    let basis = readTotalFlowStaked() + outstandingBefore
    let loss1 = basis * (2.0 / 7.0) > maxLoss ? maxLoss * (2.0 / 7.0) : basis * (2.0 / 7.0)
    realizeLoss(loss1)

    let basisAfter1 = readTotalFlowStaked() + readTotalFlowReceiptsOutstanding()
    let maxLoss2 = readMaxRealizableLoss()
    let loss2 = basisAfter1 * (9.0 / 13.0) > maxLoss2 ? maxLoss2 * (9.0 / 13.0) : basisAfter1 * (9.0 / 13.0)
    if loss2 > 0.0 {
        realizeLoss(loss2)
    }

    let outstandingAfterLosses = readTotalFlowReceiptsOutstanding()

    // Advance past both receipts' unlock epoch and mature the mock's unstaking bucket so
    // ordinary `withdraw()` (not the admin recovery path) can settle them -- the amounts
    // slashed above never touched `unstaking`/`unstaked`, so there is no physical
    // shortfall here, only the loss-ratio accounting applied in `realizeLoss()`.
    advanceEpoch(3)

    let userAFlowBefore = readFlowBalance(userA.address)
    withdraw(userA, uuidA)
    let userAReceived = readFlowBalance(userA.address) - userAFlowBefore

    let userBFlowBefore = readFlowBalance(userB.address)
    withdraw(userB, uuidB)
    let userBReceived = readFlowBalance(userB.address) - userBFlowBefore

    // The core invariant: settling every receipt that was outstanding at the time the
    // losses were realized must never pay out, in total, more than what was recorded as
    // reserved for them. Without capping each settlement at the live
    // totalFlowReceiptsOutstanding, independent rounding of outstandingLossFactor vs. the
    // aggregate counter could let this sum exceed `outstandingAfterLosses` by a dust
    // amount, with the excess silently drawn from FLOW backing sFLOW instead of being
    // reflected in the receipt accounting.
    Test.assert(
        userAReceived + userBReceived <= outstandingAfterLosses,
        message: "settled receipts paid out \(userAReceived + userBReceived), more than the \(outstandingAfterLosses) recorded as outstanding"
    )

    // Every outstanding claim has now been settled; the aggregate counter must be back to
    // exactly zero (releaseOutstanding floors at zero rather than underflowing).
    Test.assertEqual(0.0, readTotalFlowReceiptsOutstanding())
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
    let r = mintFlow(to: protocolAccount, amount: 200_000.0)
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
fun realizeLoss(_ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/transactions/admin/realize_loss.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun withdraw(_ acct: Test.TestAccount, _ uuid: UInt64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_withdraw.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [uuid],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun readFlowBalance(_ address: Address): UFix64 {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_flow_balance.cdc"),
        [address]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
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
fun readTotalFlowReceiptsOutstanding(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.totalFlowReceiptsOutstanding }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun readMaxRealizableLoss(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.maxRealizableLoss() }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}
