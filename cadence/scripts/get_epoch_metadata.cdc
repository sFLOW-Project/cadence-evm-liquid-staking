import FlowEpoch from 0x9eca2b38b18b5dfe

access(all) fun main(): FlowEpoch.EpochMetadata {
    return FlowEpoch.getEpochMetadata(3276)!
}

access(all) fun getimestamp(targetView: UInt64): UFix64? {
    let latestBlock = getCurrentBlock()

    // Return nil if the target view has not occurred yet
    if targetView > latestBlock.view {
        return nil
    }

    var low: UInt64 = 0
    var high: UInt64 = latestBlock.height
    var resultTimestamp: UFix64? = nil

    // Binary search for the first block with view >= targetView
    while low <= high {
        let mid = low + (high - low) / 2
        if let block = getBlock(at: mid) {
            if block.view >= targetView {
                resultTimestamp = block.timestamp
                if mid == 0 { break }
                high = mid - 1
            } else {
                low = mid + 1
            }
        } else {
            // If mid is pruned on this access node, narrow from the bottom
            low = mid + 1
        }
    }

    return resultTimestamp
}