import Foundation

/// Layout changes shared by the drag preview and the committed drop.
public enum LaunchpadGridReorder {
    public static func inserting(
        _ movingIDs: Set<String>,
        in order: [String],
        at destination: Int
    ) -> [String]? {
        let boundary = min(max(destination, 0), order.count)
        let block = order.filter { movingIDs.contains($0) }
        guard !block.isEmpty else { return nil }
        var remaining = order.filter { !movingIDs.contains($0) }
        let removedBefore = order.prefix(boundary).count { movingIDs.contains($0) }
        remaining.insert(contentsOf: block, at: boundary - removedBefore)
        return remaining == order ? nil : remaining
    }

    /// Translate the selection by the anchor's displacement. Occupants of its
    /// new slots move into the vacated slots in their original slot order.
    public static func placements(
        _ movingIDs: Set<String>,
        in slots: [String: Int],
        anchorID: String,
        destination: Int,
        slotLimit: Int
    ) -> [String: Int]? {
        guard movingIDs.contains(anchorID),
              let anchorSlot = slots[anchorID],
              destination >= 0, destination < slotLimit,
              destination != anchorSlot else { return nil }

        let delta = destination - anchorSlot
        var changes: [String: Int] = [:]
        var oldSlots = Set<Int>()
        var newSlots = Set<Int>()
        for id in movingIDs {
            guard let oldSlot = slots[id] else { continue }
            let newSlot = oldSlot + delta
            guard newSlot >= 0, newSlot < slotLimit else { return nil }
            changes[id] = newSlot
            oldSlots.insert(oldSlot)
            newSlots.insert(newSlot)
        }

        let vacated = oldSlots.subtracting(newSlots).sorted()
        let displaced = slots.filter { !movingIDs.contains($0.key) && newSlots.contains($0.value) }
            .sorted { $0.value < $1.value }
        guard displaced.count <= vacated.count else { return nil }
        for (occupant, slot) in zip(displaced, vacated) {
            changes[occupant.key] = slot
        }
        return changes
    }
}
