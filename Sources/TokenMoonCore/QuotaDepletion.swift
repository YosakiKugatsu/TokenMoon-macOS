// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct QuotaDepletionOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let consumedPercent: Double
    public let observedIntervals: Int
    public let cycles: Int
    /// Some of the selected interval cannot be followed across a history barrier.
    public let partialHistory: Bool
}

public enum QuotaDepletion {
    public static let weeklySeconds: TimeInterval = 7 * 86400

    /// Uses the same confirmed observation intervals as CPA's recent-100% view.
    /// Here they are clipped to the selected range instead of stopping at 100%.
    /// An observation at the end boundary can close an interval; a later one
    /// cannot turn a historically unconfirmed tail into selected-range usage.
    public static func options(
        observations: [QuotaWireObservation], bounds: Range<Date>, historyStart: Date? = nil
    ) -> [QuotaDepletionOption] {
        guard !bounds.isEmpty else { return [] }
        var unique: [QuotaSampleKey: QuotaWireObservation] = [:]
        var conflicts: Set<QuotaSampleKey> = []
        let candidates = observations.filter {
            $0.observedAt.timeIntervalSinceReferenceDate.isFinite && $0.observedAt <= bounds.upperBound
                && !$0.windowID.isEmpty && creatorAccountEmail($0.account) != nil
        }
        let weeklySeries = Set(candidates.lazy.filter { $0.durationSeconds == weeklySeconds }.map(\.seriesKey))
        for point in candidates where weeklySeries.contains(point.seriesKey) {
            let key = point.sampleKey
            guard !conflicts.contains(key) else { continue }
            if let prior = unique[key] {
                // CPA drops disagreeing measurements at the same instant.
                // Display labels and plans do not change a measurement.
                if prior.usedPercent != point.usedPercent || prior.resetsAt != point.resetsAt
                    || prior.durationSeconds != point.durationSeconds {
                    unique.removeValue(forKey: key)
                    conflicts.insert(key)
                }
            } else {
                unique[key] = point
            }
        }
        let series = Dictionary(grouping: unique.values, by: \.seriesKey)
        let countsByAccount = Dictionary(grouping: series.keys, by: { [$0.agent.rawValue, $0.account] })
        return series.compactMap { key, rows in
            let points = rows.sorted { $0.observedAt < $1.observedAt }
            guard let display = points.last else { return nil }
            let result = calculate(points: points, bounds: bounds, historyStart: historyStart)
            guard result.intervals > 0 else { return nil }
            let suffix = (countsByAccount[[key.agent.rawValue, key.account]]?.count ?? 0) > 1 ? " · " + display.windowLabel : ""
            return QuotaDepletionOption(
                id: key.id, title: key.agent.label + " · " + maskedAccount(display.account) + suffix,
                consumedPercent: result.consumed, observedIntervals: result.intervals,
                cycles: result.cycles, partialHistory: result.partial
            )
        }.sorted {
            if $0.consumedPercent != $1.consumedPercent { return $0.consumedPercent > $1.consumedPercent }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private static func maskedAccount(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return "***" }
        let name = parts[0]
        guard name.count > 2 else { return "***@" + parts[1] }
        let head = min(2, (name.count - 1) / 2)
        let tail = min(2, name.count - head - 1)
        return String(name.prefix(head)) + "***" + name.suffix(tail) + "@" + parts[1]
    }

    private struct Reading {
        let at: Date
        let used: Double
        let start: Date
        let reset: Date
    }

    private struct Interval {
        let start: Date
        let end: Date
        let consumed: Double
        let cycle: Int
    }

    private static func calculate(
        points: [QuotaWireObservation], bounds: Range<Date>, historyStart: Date?
    ) -> (consumed: Double, intervals: Int, cycles: Int, partial: Bool) {
        // Port of groupQuotaObservations and confirmedQuotaIntervals in the
        // CPA plugin. The group uses the last observed start, not a cached
        // scheduled expiry from an earlier point in the same cycle.
        var groups: [[Reading]] = []
        var barrier: Date?
        func setBarrier(_ at: Date) {
            if barrier.map({ at > $0 }) ?? true { barrier = at }
        }
        for point in points {
            guard let reset = point.resetsAt, reset.timeIntervalSinceReferenceDate.isFinite,
                  let duration = point.durationSeconds, duration.isFinite, duration > 0, duration <= 366 * 86_400 else {
                setBarrier(point.observedAt)
                continue
            }
            let start = reset.addingTimeInterval(-duration)
            if point.usedPercent == 0, point.observedAt < start {
                // Unused future reset predictions do not interrupt actual history.
                continue
            }
            if point.observedAt < start || point.observedAt >= reset {
                setBarrier(point.observedAt)
                continue
            }
            if !(0...100).contains(point.usedPercent) { setBarrier(point.observedAt) }
            let entry = Reading(at: point.observedAt, used: point.usedPercent, start: start, reset: reset)
            if let previous = groups.last?.last,
               entry.at < previous.reset && !(entry.start >= previous.at && previous.used > 0) {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }

        var confirmed: [Interval] = []
        for (cycle, group) in groups.enumerated() {
            guard let start = group.last?.start else { continue }
            var from = start
            var used = 0.0
            var hasBaseline = true
            var includesStart = true
            if let historyStart, historyStart > start {
                hasBaseline = false
                includesStart = false
                setBarrier(historyStart)
            }
            for point in group {
                guard (0...100).contains(point.used) else {
                    setBarrier(point.at)
                    hasBaseline = false
                    continue
                }
                if point.at < start {
                    if point.used > 0 {
                        setBarrier(start)
                        hasBaseline = false
                    }
                    continue
                }
                if !hasBaseline {
                    from = point.at
                    used = point.used
                    includesStart = false
                    hasBaseline = true
                    setBarrier(point.at)
                    continue
                }
                if point.used < used || point.at < from || (point.at == from && !includesStart && point.used != used) {
                    // A lower reading is a correction, not a new cycle or a
                    // completed interval. Later increases start from it.
                    setBarrier(point.at)
                    from = point.at
                    used = point.used
                    includesStart = false
                    continue
                }
                if point.used == used { continue }
                confirmed.append(Interval(start: from, end: point.at, consumed: point.used - used, cycle: cycle))
                from = point.at
                used = point.used
                includesStart = false
            }
        }

        var total = 0.0
        var count = 0
        var cycles: Set<Int> = []
        var newer: Interval?
        var partial = barrier.map { $0 > bounds.lowerBound } ?? false
        for interval in confirmed.reversed() {
            if interval.end < bounds.lowerBound { break }
            if let barrier, interval.start < barrier {
                partial = partial || interval.end > bounds.lowerBound
                break
            }
            if let newer, interval.end > newer.start {
                // Do not stitch overlapping observed coverage across resets.
                partial = partial || interval.end > bounds.lowerBound
                break
            }
            newer = interval
            let covered: Double
            if interval.start == interval.end {
                guard bounds.contains(interval.start) else { continue }
                covered = interval.consumed
            } else {
                let left = max(interval.start, bounds.lowerBound)
                let right = min(interval.end, bounds.upperBound)
                guard right > left else { continue }
                // Same linear boundary allocation as CPA's oldest partial
                // interval, applied at the selected range edges.
                covered = interval.consumed * right.timeIntervalSince(left) / interval.end.timeIntervalSince(interval.start)
            }
            total += covered
            count += 1
            cycles.insert(interval.cycle)
        }
        return (total, count, cycles.count, partial)
    }
}
