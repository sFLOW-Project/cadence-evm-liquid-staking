import Test
import "EVMRoute"

/// Conversion helpers used by the EVM relayer (`ufix64FlowToAttoUInt`, etc.).
access(all)
fun setup() {
    let err = Test.deployContract(
        name: "EVMRoute",
        path: "../../cadence/contracts/EVMRoute.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())
}

/// Regression: old `UInt64.max` cap rejected large FLOW amounts (~18.45 FLOW ceiling).
access(all)
fun testUfix64FlowToAttoUIntHandlesLargeFlowAmounts() {
    let largeFlow: UFix64 = 1_000_000.0
    let attoflow = readUfix64FlowToAttoUInt(largeFlow)
    let expected = readTokenUFix64ToScaledUInt256(largeFlow)
    Test.assertEqual(expected, attoflow)
    Test.assert(attoflow > 0, message: "large FLOW amount must convert to non-zero attoflow")
}

access(all)
fun testU256ToUIntAttoflowPreservesLargeWeiValues() {
    let largeFlow: UFix64 = 500_000.0
    let wei = readTokenUFix64ToScaledUInt256(largeFlow)
    let attoflow = readU256ToUIntAttoflow(wei)
    Test.assertEqual(UInt(wei), attoflow)
}

access(all)
fun readUfix64FlowToAttoUInt(_ amount: UFix64): UInt {
    let r = Test.executeScript(
        "import \"EVMRoute\"\naccess(all) fun main(v: UFix64): UInt { return EVMRoute.ufix64FlowToAttoUInt(v) }\n",
        [amount]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UInt
}

access(all)
fun readTokenUFix64ToScaledUInt256(_ amount: UFix64): UInt {
    let r = Test.executeScript(
        "import \"EVMRoute\"\naccess(all) fun main(v: UFix64): UInt { return UInt(EVMRoute.tokenUFix64ToScaledUInt256(v)) }\n",
        [amount]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UInt
}

access(all)
fun readU256ToUIntAttoflow(_ wei: UInt): UInt {
    let r = Test.executeScript(
        "import \"EVMRoute\"\naccess(all) fun main(v: UInt): UInt { return EVMRoute.u256ToUIntAttoflow(UInt256(v)) }\n",
        [wei]
    )
    Test.expect(r, Test.beSucceeded())
    return r.returnValue! as! UInt
}
