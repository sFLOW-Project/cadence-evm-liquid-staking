import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// Isolated integration test for the zero-backing edge case.
/// Unlike `LiquidStaking_test.cdc`, this file starts from a fresh chain state so
/// `totalFlowStaked` can be driven to exactly zero without interference from
/// earlier shared-state tests.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)
access(all) let userAccount: Test.TestAccount = Test.createAccount()

access(all) let mockNodeID: String = "lsp-zero-backing-node"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    setupFlowVaultZeroBacking(userAccount)
    setupSFlowVaultZeroBacking(userAccount)
    let mintResult = mintFlow(to: userAccount, amount: 1_000.0)
    Test.expect(mintResult, Test.beSucceeded())
    setupSFlowVaultZeroBacking(protocolAccount)

    // Register a delegator with 0 FLOW so the only protocol backing comes from
    // the seeded floor and subsequent user stakes. This lets us slash all staked
    // FLOW and drive totalFlowStaked to zero.
    registerProtocolDelegatorZeroBacking(nodeID: mockNodeID, amount: 0.0)
    seedProtocolOwnedSFlowZeroBacking()
}

access(all)
fun testRealizeLossToZeroBackingBlocksRateQueries() {
    let stakeAmount: UFix64 = 10.0
    Test.expect(Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [stakeAmount],
    )), Test.beSucceeded())

    let totalBefore = readTotalFlowStakedZeroBacking()
    Test.assertEqual(11.0, totalBefore) // 1.0 floor + 10.0 user

    // Slash the entire staked balance.
    slashZeroBacking(mockNodeID, 1 as UInt32, 11.0)

    // Realize the full verifiable shortfall.
    realizeLossZeroBacking(11.0)
    Test.assertEqual(0.0, readTotalFlowStakedZeroBacking())

    // Rate queries must now panic because backing is zero but sFLOW supply remains.
    let rateScript = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.flowPerSFlow() }\n",
        []
    )
    Test.expect(rateScript, Test.beFailed())
    Test.assert(
        errorIncludesZeroBacking(rateScript.error?.message, substring: "FLOW backing is zero while sFLOW supply remains"),
        message: "rate query must panic with zero backing"
    )
}

access(all)
fun testRealizeLossToZeroBackingBlocksNewStakes() {
    // Setup already left totalFlowStaked at 0 from the previous isolated test.
    Test.assertEqual(0.0, readTotalFlowStakedZeroBacking())

    let stakeTx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [10.0],
    ))
    Test.expect(stakeTx, Test.beFailed())
    Test.assert(
        errorIncludesZeroBacking(stakeTx.error?.message, substring: "Cannot mint sFLOW while FLOW backing is zero"),
        message: "stake must revert when FLOW backing is zero"
    )
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
}

access(all)
fun fundProtocol() {
    setupFlowVaultZeroBacking(protocolAccount)
    let r = mintFlow(to: protocolAccount, amount: 100_000.0)
    Test.expect(r, Test.beSucceeded())
}

access(all)
fun setupFlowVaultZeroBacking(_ acct: Test.TestAccount) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/setup_flow_token_vault.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun setupSFlowVaultZeroBacking(_ acct: Test.TestAccount) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/setup_sflow_vault.cdc"),
        authorizers: [acct.address],
        signers: [acct],
        arguments: [],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun registerProtocolDelegatorZeroBacking(nodeID: String, amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/register_protocol_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun seedProtocolOwnedSFlowZeroBacking() {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/seed_protocol_owned_sflow.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun slashZeroBacking(_ nodeID: String, _ delegatorID: UInt32, _ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/slash_delegator.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [nodeID, delegatorID, amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun realizeLossZeroBacking(_ amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/transactions/admin/realize_loss.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [amount],
    ))
    Test.expect(tx, Test.beSucceeded())
}

access(all)
fun readTotalFlowStakedZeroBacking(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.totalFlowStaked }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}

access(all)
fun errorIncludesZeroBacking(_ error: String?, substring: String): Bool {
    if error == nil {
        return false
    }
    return error!.index(of: substring) != nil
}
