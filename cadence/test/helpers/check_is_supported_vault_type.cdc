import "sFlowToken"

access(all) fun main(): Bool {
    let v <- sFlowToken.createEmptyVault(vaultType: Type<@sFlowToken.Vault>())
    let okSelf = v.isSupportedVaultType(type: v.getType())
    let okOther = v.isSupportedVaultType(type: Type<String>())
    destroy v
    return okSelf && !okOther
}
