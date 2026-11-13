// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Color slots are kept per raw model ID, never recomputed from a filtered list.
public enum ModelColorSlots {
    public static func validated(_ stored: [String: Int]) -> [String: Int] {
        var accepted: [String: Int] = [:]
        var used: Set<Int> = []
        for (model, slot) in stored.sorted(by: { $0.key < $1.key })
            where !model.isEmpty && (0..<1_000_000).contains(slot) && used.insert(slot).inserted {
            accepted[model] = slot
        }
        return accepted
    }

    /// The input is a previously validated registry. New IDs receive new slots
    /// in a deterministic order; unseen or filtered-out models keep their slot.
    public static func adding(_ models: Set<String>, to slots: [String: Int]) -> [String: Int] {
        let missing = models.filter { !$0.isEmpty && slots[$0] == nil }.sorted()
        guard !missing.isEmpty else { return slots }
        var updated = slots
        let next = (slots.values.max() ?? -1) + 1
        for (offset, model) in missing.enumerated() { updated[model] = next + offset }
        return updated
    }
}
