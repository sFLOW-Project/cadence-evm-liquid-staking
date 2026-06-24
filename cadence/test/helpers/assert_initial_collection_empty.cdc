import "LiquidStaking"

/// Sanity-check transaction. Asserts the signer has no FlowReceiptCollection yet
/// at `LiquidStaking.FlowReceiptCollectionPath`.
transaction {
    prepare(signer: auth(BorrowValue) &Account) {
        assert(
            signer.storage
                .borrow<&LiquidStaking.FlowReceiptCollection>(from: LiquidStaking.FlowReceiptCollectionPath)
                == nil,
            message: "Expected no pre-existing FlowReceiptCollection on signer"
        )
    }
}
