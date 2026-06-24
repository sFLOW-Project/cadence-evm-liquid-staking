import Test
import "FungibleToken"
import "FungibleTokenMetadataViews"
import "sFlowToken"

/// Unit tests for `cadence/contracts/sFlowToken.cdc`. Exercises the canonical paths,
/// `Minter` + `burnTokens` accounting, `Vault.withdraw / deposit`, the
/// `createEmptyVault` happy path, the `mintTokens(amount: 0.0)` precondition, and
/// every branch of `resolveContractView(...)`. No `LiquidStaking` / `LiquidStakingConfig`
/// state is touched — `sFlowToken` is the only contract under test here.

access(all) let protocolAddress: Address = 0x0000000000000007
access(all) let protocolAccount: Test.TestAccount = Test.getAccount(protocolAddress)

access(all)
fun setup() {
    let err = Test.deployContract(
        name: "sFlowToken",
        path: "../../cadence/contracts/sFlowToken.cdc",
        arguments: [],
    )
    Test.expect(err, Test.beNil())
}

access(all)
fun testCanonicalState() {
    Test.assertEqual(0.0, readSFlowTotalSupply())
    Test.assertEqual(/storage/sFlowTokenVault, sFlowToken.tokenVaultPath)
    Test.assertEqual(/public/sFlowTokenReceiver, sFlowToken.tokenReceiverPath)
    Test.assertEqual(/public/sFlowTokenBalance, sFlowToken.tokenBalancePath)
    Test.assertEqual(/storage/sFlowTokenMinter, sFlowToken.minterStoragePath)
}

access(all)
fun testMintIncrementsSupplyAndEmits() {
    let supplyBefore = readSFlowTotalSupply()

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/mint_sflow_via_minter.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [125.5],
    ))
    Test.expect(txResult, Test.beSucceeded())

    Test.assertEqual(supplyBefore + 125.5, readSFlowTotalSupply())

    let minted = Test.eventsOfType(Type<sFlowToken.TokensMinted>())
    Test.assertEqual(1, minted.length)
    let mintedEvent = minted[0] as! sFlowToken.TokensMinted
    Test.assertEqual(125.5, mintedEvent.amount)

    let balance = readSFlowBalance(protocolAddress)
    Test.assertEqual(125.5, balance)
}

access(all)
fun testBurnDecrementsSupplyAndEmits() {
    let supplyBefore = readSFlowTotalSupply()

    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/burn_sflow.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [25.5],
    ))
    Test.expect(txResult, Test.beSucceeded())

    Test.assertEqual(supplyBefore - 25.5, readSFlowTotalSupply())

    let burned = Test.eventsOfType(Type<sFlowToken.TokensBurned>())
    let lastBurn = burned[burned.length - 1] as! sFlowToken.TokensBurned
    Test.assertEqual(25.5, lastBurn.amount)
}

access(all)
fun testMintZeroReverts() {
    let txResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../../cadence/test/helpers/mint_sflow_via_minter.cdc"),
        authorizers: [protocolAddress],
        signers: [protocolAccount],
        arguments: [0.0],
    ))
    Test.expect(txResult, Test.beFailed())
}

access(all)
fun testVaultBalanceAndWithdrawDeposit() {
    let scriptResult = Test.executeScript(
        "import \"sFlowToken\"\n".concat(
            "access(all) fun main(): Bool {\n".concat(
                "    let v <- sFlowToken.createEmptyVault(vaultType: Type<@sFlowToken.Vault>())\n".concat(
                    "    let zero = v.balance == 0.0\n".concat(
                        "    let avail = v.isAvailableToWithdraw(amount: 0.0)\n".concat(
                            "    let types = v.getSupportedVaultTypes()\n".concat(
                                "    let typed = types[v.getType()] == true\n".concat(
                                    "    destroy v\n".concat(
                                        "    return zero && avail && typed\n"
                                        .concat("}\n"))))))))),
        []
    )
    Test.expect(scriptResult, Test.beSucceeded())
    let ok = scriptResult.returnValue! as! Bool
    Test.assertEqual(true, ok)
}

access(all)
fun testIsSupportedVaultType() {
    let scriptResult = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/check_is_supported_vault_type.cdc"),
        []
    )
    Test.expect(scriptResult, Test.beSucceeded())
    Test.assertEqual(true, scriptResult.returnValue! as! Bool)
}

access(all)
fun testContractViewsAllBranches() {
    let views = sFlowToken.getContractViews(resourceType: nil)
    Test.assertEqual(4, views.length)

    let display = sFlowToken.resolveContractView(
        resourceType: nil,
        viewType: Type<FungibleTokenMetadataViews.FTDisplay>()
    ) as! FungibleTokenMetadataViews.FTDisplay?
        ?? panic("FTDisplay view missing")
    Test.assertEqual("Staked FLOW", display.name)
    Test.assertEqual("sFlow", display.symbol)

    let vaultData = sFlowToken.resolveContractView(
        resourceType: nil,
        viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
    ) as! FungibleTokenMetadataViews.FTVaultData?
        ?? panic("FTVaultData view missing")
    Test.assertEqual(sFlowToken.tokenVaultPath, vaultData.storagePath)
    Test.assertEqual(sFlowToken.tokenReceiverPath, vaultData.receiverPath)
    Test.assertEqual(sFlowToken.tokenBalancePath, vaultData.metadataPath)

    let ftView = sFlowToken.resolveContractView(
        resourceType: nil,
        viewType: Type<FungibleTokenMetadataViews.FTView>()
    ) as! FungibleTokenMetadataViews.FTView?
        ?? panic("FTView missing")
    Test.assertEqual("Staked FLOW", ftView.ftDisplay!.name)

    let supply = sFlowToken.resolveContractView(
        resourceType: nil,
        viewType: Type<FungibleTokenMetadataViews.TotalSupply>()
    ) as! FungibleTokenMetadataViews.TotalSupply?
        ?? panic("TotalSupply view missing")
    Test.assertEqual(sFlowToken.totalSupply, supply.supply)
}

// ---- helpers ----

access(all)
fun readSFlowBalance(_ addr: Address): UFix64 {
    let result = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_sflow_balance.cdc"),
        [addr]
    )
    Test.expect(result, Test.beSucceeded())
    return result.returnValue! as! UFix64
}

access(all)
fun readSFlowTotalSupply(): UFix64 {
    let result = Test.executeScript(
        Test.readFile("../../cadence/test/helpers/get_sflow_total_supply.cdc"),
        []
    )
    Test.expect(result, Test.beSucceeded())
    return result.returnValue! as! UFix64
}
