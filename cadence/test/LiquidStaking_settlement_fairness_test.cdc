import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// When a shared delegator slot cannot satisfy every claim that has
/// matured against it (a genuine physical shortfall, e.g. from slashing), every due claim
/// must absorb the shortfall pro-rata instead of whichever claim settles first draining the
/// slot and leaving later claimants with less (first-come-first-served).
///
/// Isolated (fresh-chain) test, following the same pattern as
/// `LiquidStaking_zero_backing_test.cdc` / `LiquidStaking_reward_rounding_test.cdc`.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userA: Test.TestAccount = Test.createAccount()
access(all) let userB: Test.TestAccount = Test.createAccount()

access(all) let mockNodeID: String = "lsp-fairness-node"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    registerProtocolDelegator(nodeID: mockNodeID, amount: 1_000.0)
    seedProtocolOwnedSFlow()

    setupFlowVault(userA)
    setupSFlowVault(userA)
    Test.expect(mintFlow(to: userA, amount: 1_000.0), Test.beSucceeded())

    setupFlowVault(userB)
    setupSFlowVault(userB)
    Test.expect(mintFlow(to: userB, amount: 1_000.0), Test.beSucceeded())
}

access(all)
fun testSharedSlotShortfallSplitsProRataAcrossDueClaims() {
    // Two users each stake and then unstake 100.0 FLOW. Since nothing is exiting yet,
    // both unstakes allocate a single "new request" leg against the same slot (slot 0),
    // both with the same unlockEpoch (current + 2) -- i.e. both claims become "due" at
    // exactly the same epoch, competing for the same slot liquidity.
    stake(userA, 100.0)
    let uuidA = unstakeAndGetReceiptUuid(userA, 100.0)

    stake(userB, 100.0)
    let uuidB = unstakeAndGetReceiptUuid(userB, 100.0)

    // Advance 2 epochs so both legs' unlockEpoch has passed, and mature the mock's
    // unstaking bucket so the FLOW physically lands in tokensUnstaked.
    advanceEpoch(2)

    // Simulate a slashing event that removes 50.0 FLOW from what is now sitting in the
    // delegator's unstaked bucket: 200.0 was due (100 + 100), but only 150.0 remains
    // physically available -- a genuine 25% shortfall shared by both due claims.
    slashUnstaked(nodeID: mockNodeID, delegatorID: 1, amount: 50.0)

    let userAFlowBefore = readFlowBalance(userA.address)
    let userBFlowBefore = readFlowBalance(userB.address)

    // Settle A first via the admin recovery path (ordinary `withdraw()` would revert here
    // since the full `effective` amount is no longer available). Under the previous
    // first-come-first-served behavior, A would receive the full 100.0 (slot had 150.0
    // available, A's leg only needed 100.0) and B would be left with only 50.0 -- an unfair,
    // order-dependent outcome. With the pro-rata fix, each due claim absorbs the shortfall by
    // the same ratio (150.0 available / 200.0 due = 0.75), so A must receive exactly 75.0
    // regardless of settlement order.
    withdrawStuck(userA, uuidA)
    let userAReceived = readFlowBalance(userA.address) - userAFlowBefore
    Test.assertEqual(75.0, userAReceived)

    // B settles second and must receive the *same* pro-rata share as A, not merely
    // whatever liquidity A left behind.
    withdrawStuck(userB, uuidB)
    let userBReceived = readFlowBalance(userB.address) - userBFlowBefore
    Test.assertEqual(75.0, userBReceived)

    // Conservation: the two payouts must sum to exactly what was physically available.
    Test.assertEqual(150.0, userAReceived + userBReceived)
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
