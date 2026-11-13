// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Scoped to a single decoder or ingestion pass. The rows own their final
/// strings; the lookup table can be freed as soon as ingestion finishes.
public final class UsageStringInterner: @unchecked Sendable {
    public static let key = CodingUserInfoKey(rawValue: "TokenMoon.usageStringInterner")!
    private let lock = NSLock()
    private var strings: Set<String> = []
    private let capacity: Int

    public init(capacity: Int = 65_536) { self.capacity = max(0, capacity) }

    func canonicalize(_ value: inout String) {
        // Small ASCII strings already live inline in the String value.
        guard value.utf8.count > 15 else { return }
        lock.withLock {
            if let index = strings.firstIndex(of: value) {
                // Swift String equality folds canonically equivalent Unicode.
                // Keep the source spelling when the UTF-8 bytes differ.
                let shared = strings[index]
                if shared.utf8.elementsEqual(value.utf8) { value = shared }
            } else if strings.count < capacity {
                strings.insert(value)
            }
        }
    }

    func canonicalize(_ value: inout String?) {
        guard var string = value else { return }
        canonicalize(&string)
        value = string
    }
}
