import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// `LiquidStakingConfig.withdrawClaimPartial()`'s pro-rata haircut
/// (`take = leg.amount * available / dueNow`) previously multiplied two `UFix64` values
/// directly. `UFix64` multiplication overflows (panics) once the product of the two
/// operands exceeds roughly 1.8447e11, which realistic FLOW amounts in the hundreds of
/// thousands can reach (`leg.amount = 500,000.0` and `available = 900,000.0` already
/// multiply to `4.5e11`). Left unfixed, any receipt on a sufficiently large, short slot
/// could never be settled through ordinary withdrawal, holder settlement, or admin
/// eviction -- every call into the pro-rata branch would revert with `overflow`.
///
/// Isolated (fresh-chain) test, following the same pattern as
/// `LiquidStaking_settlement_fairness_test.cdc`, scaled up so the pro-rata multiplication
/// actually exercises the overflow-prone magnitude.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userA: Test.TestAccount = Test.createAccount()
access(all) let userB: Test.TestAccount = Test.createAccount()

access(all) let mockNodeID: String = "lsp-claim-overflow-node"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    registerProtocolDelegator(nodeID: mockNodeID, amount: 1_000.0)
    seedProtocolOwnedSFlow()

    setupFlowVault(userA)
    setupSFlowVault(userA)
    Test.expect(mintFlow(to: userA, amount: 500_000.0), Test.beSucceeded())

    setupFlowVault(userB)
    setupSFlowVault(userB)
    Test.expect(mintFlow(to: userB, amount: 500_000.0), Test.beSucceeded())
}

access(all)
fun testLargeClaimOnShortSlotSettlesWithoutOverflow() {
    // Both users stake and unstake their full 500,000.0 FLOW against the same slot, so
    // both claims become due at the same epoch with a combined 1,000,000.0 FLOW due now
    // (leg.amount = 500,000.0 each).
    stake(userA, 500_000.0)
    let uuidA = unstakeAndGetReceiptUuid(userA, 500_000.0)

    stake(userB, 500_000.0)
    let uuidB = unstakeAndGetReceiptUuid(userB, 500_000.0)

    advanceEpoch(2)

    // Leave the slot short by 100,000.0: 900,000.0 available against 1,000,000.0 due.
    // `leg.amount * available` (500,000.0 * 900,000.0 = 4.5e11) directly exceeds UFix64's
    // safe multiplication range (~1.8447e11) -- the previous direct-UFix64 multiplication
    // would panic with `overflow` here.
    slashUnstaked(nodeID: mockNodeID, delegatorID: 1, amount: 100_000.0)

    let userAFlowBefore = readFlowBalance(userA.address)
    withdrawStuck(userA, uuidA)
    let userAReceived = readFlowBalance(userA.address) - userAFlowBefore
    Test.assertEqual(450_000.0, userAReceived)

    let userBFlowBefore = readFlowBalance(userB.address)
    withdrawStuck(userB, uuidB)
    let userBReceived = readFlowBalance(userB.address) - userBFlowBefore
    Test.assertEqual(450_000.0, userBReceived)

    Test.assertEqual(900_000.0, userAReceived + userBReceived)
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
fun slashUnstaked(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/slash_unstaked.cdc"),
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
fun readFlowBalance(_ address: Address): UFix64 {
    let r = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_flow_balance.cdc"),
        [address]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}
