import "RelayerRouter"

transaction {
    prepare(_signer: &Account) {}
    execute {
        RelayerRouter.compoundAndSyncRate()
    }
}
