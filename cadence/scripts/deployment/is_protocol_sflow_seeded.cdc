import "LiquidStaking"

/// True once `seed_protocol_owned_sflow.cdc` has run (protocol-owned sFLOW floor locked).
/// Used by the deploy pipeline to skip re-seeding on re-run.
access(all) fun main(): Bool {
    return LiquidStaking.isProtocolOwnedSFlowSeeded()
}
