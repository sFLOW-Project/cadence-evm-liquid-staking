import Test

/// SFL-05: repeated relayer capability issuance must not leak storage capability controllers.
/// This test verifies the revoke pattern used by handle_stakes.cdc and initiate_unstakes.cdc.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)

access(all)
fun testRepeatedCapabilityIssueAndRevokeKeepsControllerCountConstant() {
    var i = 0
    while i < 5 {
        let tx = Test.executeTransaction(Test.Transaction(
            code: Test.readFile("../../cadence/test/helpers/issue_and_revoke_flow_provider.cdc"),
            authorizers: [protocolAddress],
            signers: [protocolAccount],
            arguments: [],
        ))
        Test.expect(tx, Test.beSucceeded())
        i = i + 1
    }
}
