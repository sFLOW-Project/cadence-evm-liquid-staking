import Test
import BlockchainHelpers
import "FlowToken"
import "FungibleToken"
import "FlowEpoch"
import "FlowIDTableStaking"
import "sFlowToken"
import "LiquidStaking"
import "LiquidStakingConfig"

/// `LiquidStaking.actualDelegatorBacking()` must measure net rewards
/// using the exact same rounding basis as `LiquidStakingConfig.compoundAll()`
/// (`fee = gross * feePercent; net = gross - fee`), not the mathematically-equivalent-in-
/// reals-but-UFix64-divergent `gross * (1 - feePercent)`. With `gross = 33.33333333` and
/// `feePercent = 0.1`, the two formulas disagree by exactly one UFix64 ULP
/// (`net = 29.99999999` vs `30.00000000`), which previously surfaced as a phantom 1e-8 FLOW
/// "verifiable shortfall" in `maxRealizableLoss()` even though no actual loss occurred.
///
/// Isolated (fresh-chain) test, following the same pattern as
/// `LiquidStaking_zero_backing_test.cdc`, so the boundary reward amount is not perturbed by
/// other shared-state tests.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)

access(all) let mockNodeID: String = "lsp-reward-rounding-node"

access(all)
fun setup() {
    deployAll()
    fundProtocol()
    registerProtocolDelegator(nodeID: mockNodeID, amount: 100.0)
    seedProtocolOwnedSFlow()
    seedRewardPool(amount: 1_000.0)
}

access(all)
fun testNetRewardRoundingMatchesCompoundAllBasis() {
    // `registerProtocolDelegator(amount: 100.0)` funds the mock delegator's staked bucket
    // directly (outside `LiquidStaking.totalFlowStaked` tracking, mirroring the pattern used
    // in `LiquidStaking_test.cdc`'s own loss-realization tests), so actual backing starts
    // well above `totalFlowStaked`. Stake 30.0 more through the normal path (totalFlowStaked
    // now 31.0 = 1.0 protocol-owned floor + 30.0 stake; actual backing 131.0 = 100.0 + 31.0),
    // then slash 130.0 out of the combined staked bucket so actual backing drops to 1.0 --
    // a genuine, verifiable 30.0 FLOW shortfall against the 31.0 basis.
    let stakeTx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/user_stake.cdc"),
        authorizers: [protocolAccount.address],
        signers: [protocolAccount],
        arguments: [30.0],
    ))
    Test.expect(stakeTx, Test.beSucceeded())

    slashDelegator(nodeID: mockNodeID, delegatorID: 1, amount: 130.0)
    Test.assertEqual(30.0, readMaxRealizableLoss())

    // Accrue a reward whose net-of-fee amount, under the *correct* rounding basis
    // (`gross - gross*feePercent`), exactly closes the 30.0 shortfall:
    // 33.33333333 - 33.33333333 * 0.1 == 30.00000000.
    // Under the previously-used, mathematically-equivalent-in-reals formula
    // (`gross * (1 - feePercent)`), the same inputs round down to 29.99999999 under
    // Cadence's UFix64 fixed-point truncation, which would leave a phantom 0.00000001 FLOW
    // "shortfall" reported by `maxRealizableLoss()` even though the real shortfall has been
    // fully closed by the reward.
    let grossReward: UFix64 = 33.33333333
    accrueRewards(nodeID: mockNodeID, delegatorID: 1, amount: grossReward)

    Test.assertEqual(0.0, readMaxRealizableLoss())
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
fun accrueRewards(nodeID: String, delegatorID: UInt32, amount: UFix64) {
    let tx = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/accrue_rewards.cdc"),
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
fun readMaxRealizableLoss(): UFix64 {
    let r = Test.executeScript(
        "import \"LiquidStaking\"\naccess(all) fun main(): UFix64 { return LiquidStaking.maxRealizableLoss() }\n",
        []
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UFix64
}
