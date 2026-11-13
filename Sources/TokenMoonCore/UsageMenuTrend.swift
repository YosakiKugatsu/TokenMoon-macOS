// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Six equal, elapsed four-hour intervals over the same rolling 24 hours as
/// the menu's totals. Civil clock transitions never add or remove a column.
public struct UsageMenuTrend: Sendable {
    public static let count = 6
    public static let step: TimeInterval = 4 * 3600
    public let bounds: Range<Date>

    public init(now: Date) {
        bounds = now.addingTimeInterval(-Self.step * Double(Self.count))..<now
    }

    public func index(of timestamp: Date) -> Int? {
        guard bounds.contains(timestamp) else { return nil }
        return min(Self.count - 1, Int(timestamp.timeIntervalSince(bounds.lowerBound) / Self.step))
    }

    public func nextChange(for timestamp: Date, index: Int) -> Date {
        timestamp.addingTimeInterval(Self.step * Double(Self.count - index))
    }
}
