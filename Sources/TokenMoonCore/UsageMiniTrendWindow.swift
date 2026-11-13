// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Hourly clock-aligned cells in the popup's exact rolling 24-hour range.
/// Their identities stay aligned while the two clipped ends slide.
public struct UsageMiniTrendWindow: Sendable {
    public struct Cell: Identifiable, Equatable, Sendable {
        public let id: Date
        public let bounds: Range<Date>
    }

    public let bounds: Range<Date>
    public let cells: [Cell]
    public let nextGridChange: Date?

    public init(now: Date, calendar: Calendar) {
        let duration: TimeInterval = 24 * 3600
        let bounds = now.addingTimeInterval(-duration)..<now
        let interval = UsageBucketInterval.hour
        let grid = interval.buckets(in: bounds, calendar: calendar)
        self.bounds = bounds
        cells = grid.map { Cell(id: $0.start, bounds: max($0.start, bounds.lowerBound)..<min($0.end, now)) }
        let nextStart = grid.first?.end.addingTimeInterval(duration)
        let nextEnd = interval.interval(containing: now, calendar: calendar)?.end
        nextGridChange = [nextStart, nextEnd].compactMap { $0 }.min()
    }

    public func cellIndex(containing date: Date) -> Int? {
        guard bounds.contains(date) else { return nil }
        var lower = 0
        var upper = cells.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if date < cells[middle].bounds.upperBound { upper = middle }
            else { lower = middle + 1 }
        }
        return cells.indices.contains(lower) && cells[lower].bounds.contains(date) ? lower : nil
    }
}
