// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A real provider reading. The history needs no account display name or credentials.
public struct QuotaObservation: Codable, Equatable, Sendable {
    public let accountID: String
    public let windowID: String
    public let observedAt: Date
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(accountID: String, windowID: String, observedAt: Date, usedPercent: Double, resetsAt: Date? = nil) {
        self.accountID = accountID
        self.windowID = windowID
        self.observedAt = observedAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public init?(account: QuotaAccount, window: QuotaWindow) {
        guard let observedAt = account.liveObservationAt,
              window.resetsAt.map({ $0 > observedAt }) ?? true else { return nil }
        self.init(accountID: account.id, windowID: window.id, observedAt: observedAt,
                  usedPercent: window.usedPercent, resetsAt: window.resetsAt)
    }

    fileprivate var series: Series { Series(accountID: accountID, windowID: windowID) }
    fileprivate var valid: Bool {
        !accountID.isEmpty && !windowID.isEmpty && usedPercent.isFinite
            && (0...100).contains(usedPercent) && observedAt.timeIntervalSinceReferenceDate.isFinite
            && (resetsAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
    }

    fileprivate struct Series: Hashable {
        let accountID: String
        let windowID: String
    }
}

public struct QuotaPrediction: Equatable, Sendable {
    /// A zero crossing before the next reset, or with no reset date available.
    public let exhaustsAt: Date?
    public let lastsUntilReset: Bool
    public let sampleCount: Int
    public let percentagePointsPerHour: Double
}

public enum QuotaForecast {
    public static let minimumSamples = 3
    public static let minimumObservationSpan: TimeInterval = 60 * 60
    private static let lookback: TimeInterval = 7 * 24 * 60 * 60
    private static let resetSlack: TimeInterval = 5 * 60
    private static let readingGap: TimeInterval = 5 * 60
    private static let nearDuplicateGap: TimeInterval = 30
    private static let maxReadingsPerWindow = 2_048

    /// Fits the last uninterrupted run of remaining percentages, then projects its zero crossing.
    /// The source's current percentage remains authoritative and is never replaced by the fit.
    public static func estimate(
        account: QuotaAccount, window: QuotaWindow, observations: [QuotaObservation], now: Date = .now
    ) -> QuotaPrediction? {
        guard account.freshness(for: window, now: now) == .fresh,
              let current = QuotaObservation(account: account, window: window),
              current.valid, current.usedPercent < 100 else { return nil }

        var lowerBound = now.addingTimeInterval(-lookback)
        if let reset = current.resetsAt, let duration = window.durationSeconds, duration.isFinite, duration > 0 {
            let windowStart = reset.addingTimeInterval(-duration)
            guard windowStart <= current.observedAt else { return nil }
            lowerBound = max(lowerBound, windowStart)
        }

        var byDate: [Date: QuotaObservation] = [:]
        for sample in observations where sample.valid && sample.series == current.series
            && sample.observedAt >= lowerBound && sample.observedAt <= current.observedAt {
            byDate[sample.observedAt] = sample
        }
        byDate[current.observedAt] = current
        let sorted = byDate.values.sorted { $0.observedAt < $1.observedAt }
        var start = sorted.count - 1
        while start > 0 {
            let before = sorted[start - 1], after = sorted[start]
            guard before.usedPercent <= after.usedPercent, !startsNewCycle(before, after) else { break }
            start -= 1
        }
        let readings = sorted[start...]
        guard readings.count >= minimumSamples, let first = readings.first,
              current.observedAt.timeIntervalSince(first.observedAt) >= minimumObservationSpan else { return nil }

        // Center the measurements before fitting so absolute epoch times cannot reduce precision.
        let points = readings.map { (hours: $0.observedAt.timeIntervalSince(first.observedAt) / 3_600,
                                     remaining: 100 - $0.usedPercent) }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.hours } / count
        let meanY = points.reduce(0) { $0 + $1.remaining } / count
        let variance = points.reduce(0) { $0 + ($1.hours - meanX) * ($1.hours - meanX) }
        guard variance > 0 else { return nil }
        let slope = points.reduce(0) { $0 + ($1.hours - meanX) * ($1.remaining - meanY) } / variance
        guard slope.isFinite else { return nil }
        guard slope < 0 else {
            guard current.resetsAt != nil else { return nil }
            return QuotaPrediction(exhaustsAt: nil, lastsUntilReset: true,
                                   sampleCount: points.count, percentagePointsPerHour: 0)
        }
        let crossingSeconds = (meanX - meanY / slope) * 3_600
        guard crossingSeconds.isFinite else { return nil }
        let exhaustsAt = first.observedAt.addingTimeInterval(crossingSeconds)
        guard exhaustsAt > now else { return nil }
        let lasts = current.resetsAt.map { exhaustsAt >= $0 } ?? false
        return QuotaPrediction(exhaustsAt: lasts ? nil : exhaustsAt, lastsUntilReset: lasts,
                               sampleCount: points.count, percentagePointsPerHour: -slope)
    }

    /// Deduplicates repeated poll results and caps local history to the prediction's lookback.
    /// Keeps both ends of a flat run and keeps readings on either side of a reset.
    public static func recording(
        accounts: [QuotaAccount], into observations: [QuotaObservation], now: Date = .now
    ) -> [QuotaObservation] {
        let cutoff = now.addingTimeInterval(-lookback)
        let existing = observations.filter { $0.valid && $0.observedAt >= cutoff && $0.observedAt <= now }
        var groups = Dictionary(grouping: existing.sorted { $0.observedAt < $1.observedAt }, by: \.series)
        let new = accounts.flatMap { account in account.windows.compactMap { QuotaObservation(account: account, window: $0) } }
            .filter { $0.valid && $0.observedAt >= cutoff && $0.observedAt <= now }
            .sorted { $0.observedAt < $1.observedAt }
        for sample in new {
            append(sample, to: &groups[sample.series, default: []])
        }
        return groups.values.flatMap { $0.suffix(maxReadingsPerWindow) }.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
            return $0.windowID < $1.windowID
        }
    }

    private static func append(_ sample: QuotaObservation, to series: inout [QuotaObservation]) {
        guard let last = series.last else { series.append(sample); return }
        guard sample.observedAt > last.observedAt else { return }
        if !startsNewCycle(last, sample), sample.usedPercent >= last.usedPercent {
            if series.count >= 2 {
                let penultimate = series[series.count - 2]
                let flat = abs(sample.usedPercent - last.usedPercent) < 0.05
                    && abs(last.usedPercent - penultimate.usedPercent) < 0.05
                if !startsNewCycle(penultimate, last), last.usedPercent >= penultimate.usedPercent,
                   flat || sample.observedAt.timeIntervalSince(penultimate.observedAt) < readingGap {
                    series[series.count - 1] = sample
                    return
                }
            }
            if sample.observedAt.timeIntervalSince(last.observedAt) < nearDuplicateGap {
                series[series.count - 1] = sample
                return
            }
        }
        series.append(sample)
    }

    private static func startsNewCycle(_ before: QuotaObservation, _ after: QuotaObservation) -> Bool {
        guard let oldReset = before.resetsAt else {
            return after.resetsAt != nil || after.usedPercent < before.usedPercent - 5
        }
        guard let newReset = after.resetsAt, oldReset > after.observedAt else { return true }
        let elapsed = after.observedAt.timeIntervalSince(before.observedAt)
        let shift = newReset.timeIntervalSince(oldReset)
        let rolling = shift > 0 && abs(shift - elapsed) <= resetSlack
        if !rolling && abs(shift) <= resetSlack && after.usedPercent < before.usedPercent - 5 { return true }
        return shift > elapsed + resetSlack || shift < -resetSlack
    }
}
