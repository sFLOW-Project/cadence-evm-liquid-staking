import "LiquidStakingConfig"

access(all) contract RelayerRouter {
    access(all) fun syncRate(rateScaled: UInt256, admin: &LiquidStakingConfig.Admin) {
        let _rate = rateScaled
        let _admin = admin
    }
}
