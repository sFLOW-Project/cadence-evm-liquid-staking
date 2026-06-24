import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowIDTableStaking"
import "LiquidStakingConfig"

/// Unit tests for the **non-EVM** surface of `LiquidStakingConfig`.
///
/// The Cadence test runtime can't bootstrap an `LSPVault` on the EVM side, so we
/// deploy `cadence/test/fixtures/LiquidStakingConfigStub.cdc` here instead of the
/// real `cadence/contracts/LiquidStakingConfig.cdc`. The stub is a byte-for-byte
/// mirror of every non-EVM behavior:
///   * identical init preconditions (`fee <= 0.2`, non-zero receiver/min, `delay <= 2`)
///   * identical event signatures + storage paths
///   * identical Admin surface for `registerDelegator`, `setProtocolFeeReceiver`,
///     `setUnstakeUnlockEpochDelay`, `setStakingPaused`, `setMinOperationAmount`,
///     `setProtocolFee` (queue) and `activateProtocolFee` (activation)
/// All EVM-mirror calls (`EVMRoute.set*`) and EVM getters
/// (`lspVaultEVMAddress`, `governanceCoaEVMAddress`) are documented as
/// integration-test scope and are not exercised here.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)

access(all) let stubPath: String = "../../cadence/test/fixtures/LiquidStakingConfigStub.cdc"

access(all)
fun setup() {
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

    setupFlowVault(protocolAccount)
    let mintResult = mintFlow(to: protocolAccount, amount: 1_000.0)
    Test.expect(mintResult, Test.beSucceeded())
}

// ---- init constraint failures ----
//
// All four init preconditions are exercised in one test function so we only need
// to commit blocks between the attempts (each `deployContract` opens a pending
// block; chaining many failed deploys across separate test functions hits a
// "pending block currently being executed" framework bug).

access(all)
fun testInitConstraintsRejectInvalidArgs() {
    let cases: [{String: AnyStruct}] = [
        {"label": "fee > 0.2", "args": [0.25, protocolAddress, 1.0, 0 as UInt64]},
        {"label": "zero receiver", "args": [0.1 as UFix64, Address(0x0), 1.0, 0 as UInt64]},
        {"label": "min == 0", "args": [0.1 as UFix64, protocolAddress, 0.0, 0 as UInt64]},
        {"label": "delay > 2", "args": [0.1 as UFix64, protocolAddress, 1.0, 3 as UInt64]}
    ]
    var i = 0
    while i < cases.length {
        let label = cases[i]["label"]! as! String
        let args = cases[i]["args"]! as! [AnyStruct]
        let err = Test.deployContract(
            name: "LiquidStakingConfig",
            path: stubPath,
            arguments: args,
        )
        Test.assert(err != nil, message: "expected init to fail for ".concat(label))
        Test.commitBlock()
        i = i + 1
    }
}

// ---- successful init + everything below depends on this contract being deployed ----

access(all)
fun testInitSucceeds() {
    let err = Test.deployContract(
        name: "LiquidStakingConfig",
        path: stubPath,
        arguments: [0.1, protocolAddress, 1.0, 0 as UInt64],
    )
    Test.expect(err, Test.beNil())

    let snap = readConfigSnapshot()
    Test.assertEqual(0.1, snap[1] as! UFix64)            // fee
    Test.assertEqual(protocolAddress, snap[0] as! Address)
    Test.assertEqual(1.0, snap[5] as! UFix64)            // min
    Test.assertEqual(0 as UInt64, snap[6] as! UInt64)    // delay
    Test.assertEqual(false, snap[4] as! Bool)            // paused
    Test.assertEqual(nil, snap[2])                       // pctQueued
    Test.assertEqual(/public/flowTokenReceiver, LiquidStakingConfig.ProtocolFeeReceiverPublicPath)
    Test.assertEqual(/storage/liquidStakingAdmin, LiquidStakingConfig.AdminStoragePath)
    Test.assertEqual(/storage/liquidStakingDelegator, LiquidStakingConfig.DelegatorStoragePath)
    Test.assertEqual(/storage/liquidStakingWithdrawPool, LiquidStakingConfig.WithdrawPoolStoragePath)
}

// ---- admin: protocolFeeReceiver ----

access(all)
fun testAdminSetProtocolFeeReceiver() {
    let newReceiverAccount = Test.createAccount()
    setupFlowVault(newReceiverAccount)

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_protocol_fee_receiver.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [newReceiverAccount.address],
    ))
    Test.expect(txResult, Test.beSucceeded())
    Test.assertEqual(newReceiverAccount.address, readConfigSnapshot()[0] as! Address)

    let evs = Test.eventsOfType(Type<LiquidStakingConfig.ProtocolFeeReceiverUpdated>())
    Test.assertEqual(1, evs.length)

    let revert = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_protocol_fee_receiver.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [protocolAddress],
    ))
    Test.expect(revert, Test.beSucceeded())
}

access(all)
fun testAdminSetProtocolFeeReceiverMissingCapabilityRejected() {
    let receiverWithoutVault: Address = 0x0000000000000099

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_protocol_fee_receiver.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [receiverWithoutVault],
    ))
    Test.expect(txResult, Test.beFailed())
}

access(all)
fun testAdminSetProtocolFeeReceiverZeroRejected() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_protocol_fee_receiver.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [Address(0x0)],
    ))
    Test.expect(txResult, Test.beFailed())
}

// ---- admin: unstakeUnlockEpochDelay ----

access(all)
fun testAdminSetUnstakeUnlockEpochDelay() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_unstake_delay.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [2 as UInt64],
    ))
    Test.expect(txResult, Test.beSucceeded())
    Test.assertEqual(2 as UInt64, readConfigSnapshot()[6] as! UInt64)

    let revert = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_unstake_delay.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [0 as UInt64],
    ))
    Test.expect(revert, Test.beSucceeded())
}

access(all)
fun testAdminSetUnstakeUnlockEpochDelayTooHigh() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_unstake_delay.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [3 as UInt64],
    ))
    Test.expect(txResult, Test.beFailed())
}

// ---- admin: minOperationAmount ----

access(all)
fun testAdminSetMinOperationAmount() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_min_operation_amount.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [2.5],
    ))
    Test.expect(txResult, Test.beSucceeded())
    Test.assertEqual(2.5, readConfigSnapshot()[5] as! UFix64)

    let revert = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_min_operation_amount.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [1.0],
    ))
    Test.expect(revert, Test.beSucceeded())
}

access(all)
fun testAdminSetMinOperationAmountZeroRejected() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_min_operation_amount.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [0.0],
    ))
    Test.expect(txResult, Test.beFailed())
}

// ---- admin: setStakingPaused ----

access(all)
fun testAdminSetStakingPausedToggles() {
    let pauseTx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_staking_paused.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [true],
    ))
    Test.expect(pauseTx, Test.beSucceeded())
    Test.assertEqual(true, readConfigSnapshot()[4] as! Bool)

    let unpause = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/set_staking_paused.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [false],
    ))
    Test.expect(unpause, Test.beSucceeded())
    Test.assertEqual(false, readConfigSnapshot()[4] as! Bool)
}

// ---- admin: setProtocolFee queue path ----

access(all)
fun testAdminQueueProtocolFee() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/queue_protocol_fee.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [0.15],
    ))
    Test.expect(txResult, Test.beSucceeded())

    let snap = readConfigSnapshot()
    Test.assertEqual(0.15 as UFix64?, snap[2] as! UFix64?)
    Test.assert((snap[3] as! UInt64) > 0 as UInt64, message: "timelock expiration must be set after queue")

    let evs = Test.eventsOfType(Type<LiquidStakingConfig.ProtocolFeeUpdateQueued>())
    Test.assert(evs.length >= 1, message: "expected ProtocolFeeUpdateQueued event")
    let last = evs[evs.length - 1] as! LiquidStakingConfig.ProtocolFeeUpdateQueued
    Test.assertEqual(0.15, last.newFee)
}

access(all)
fun testAdminQueueProtocolFeeTooHighRejected() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/queue_protocol_fee.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [0.25],
    ))
    Test.expect(txResult, Test.beFailed())
}

access(all)
fun testAdminActivateProtocolFeeBeforeTimelockReverts() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/activate_protocol_fee.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [],
    ))
    Test.expect(txResult, Test.beFailed())
    Test.assertEqual(0.1, readConfigSnapshot()[1] as! UFix64)
}

// ---- admin: registerDelegator via the staking mock ----

access(all)
fun testAdminRegisterDelegatorPersistsAndExposesInfo() {
    let registerTx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/register_protocol_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: ["mock-node", 250.0],
    ))
    Test.expect(registerTx, Test.beSucceeded())

    let infoResult = Test.executeScript(
        "import \"FlowIDTableStaking\"\n"
            .concat("import \"LiquidStakingConfig\"\n")
            .concat("access(all) fun main(): [UFix64] {\n")
            .concat("    let acct = getAuthAccount<auth(BorrowValue) &Account>(0x0000000000000007)\n")
            .concat("    let delegator = acct.storage\n")
            .concat("        .borrow<&FlowIDTableStaking.NodeDelegator>(from: LiquidStakingConfig.DelegatorStoragePath)\n")
            .concat("        ?? panic(\"delegator missing\")\n")
            .concat("    let info = FlowIDTableStaking.DelegatorInfo(nodeID: delegator.nodeID, delegatorID: delegator.id)\n")
            .concat("    return [info.tokensCommitted, info.tokensStaked, info.tokensUnstaking, info.tokensUnstaked, info.tokensRewarded]\n")
            .concat("}\n"),
        []
    )
    Test.expect(infoResult, Test.beSucceeded())
    let buckets = infoResult.returnValue! as! [UFix64]
    Test.assertEqual(5, buckets.length)
    Test.assertEqual(0.0, buckets[0])     // committed (mock collapses to staked)
    Test.assertEqual(250.0, buckets[1])   // staked
    Test.assertEqual(0.0, buckets[2])     // unstaking
    Test.assertEqual(0.0, buckets[3])     // unstaked
    Test.assertEqual(0.0, buckets[4])     // rewarded
}

// ---- helpers ----

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
fun readConfigSnapshot(): [AnyStruct] {
    let result = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_config_snapshot.cdc"),
        []
    )
    Test.expect(result, Test.beSucceeded())
    return result.returnValue! as! [AnyStruct]
}
