import "LiquidStakingConfig"

access(all) contract RelayerRouter {
    access(all) fun syncBacking(admin: &LiquidStakingConfig.Admin) {
        let _admin = admin
    }
}
