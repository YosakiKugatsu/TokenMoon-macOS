// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A padded, rounded domain for line charts. Total/stacked charts keep their
/// ordinary zero-based scale and don't use this policy.
public struct RateChartScale: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case cacheRate, throughput }

    public let domain: ClosedRange<Double>
    public let ticks: [Double]

    public static func make(_ kind: Kind, values: [Double], automatic: Bool) -> Self {
        let cap: Double? = kind == .cacheRate ? 1 : nil
        if kind == .cacheRate, !automatic {
            return .init(domain: 0...1, ticks: [0, 0.25, 0.5, 0.75, 1])
        }
        let valid = values.lazy.filter { $0.isFinite && $0 >= 0 }
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for value in valid where cap.map({ value <= $0 }) ?? true {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        guard minimum.isFinite, maximum.isFinite else {
            return .init(domain: 0...1, ticks: [0, 0.25, 0.5, 0.75, 1])
        }
        if !automatic { return rounded(from: 0, to: max(1, maximum * 1.08), cap: nil) }

        let minimumSpan = kind == .cacheRate ? 0.02 : max(2, maximum * 0.05)
        let padding = max(minimumSpan / 2, (maximum - minimum) * 0.12)
        var low = max(0, minimum - padding)
        var high = min(cap ?? .greatestFiniteMagnitude, maximum + padding)
        if high - low < minimumSpan {
            if let cap, low + minimumSpan > cap { low = max(0, high - minimumSpan) }
            else { high = low + minimumSpan }
        }
        return rounded(from: low, to: high, cap: cap)
    }

    private static func rounded(from low: Double, to high: Double, cap: Double?) -> Self {
        let raw = (high - low) / 4
        guard raw.isFinite, raw > 0 else { return .init(domain: 0...1, ticks: [0, 0.5, 1]) }
        let power = pow(10, floor(log10(raw)))
        let ratio = raw / power
        let unit = [1.0, 2, 2.5, 5, 10].first { ratio <= $0 + 1e-10 } ?? 10
        let step = unit * power
        let lower = max(0, floor(low / step + 1e-10) * step)
        let proposedUpper = ceil(high / step - 1e-10) * step
        let upper = min(cap ?? .greatestFiniteMagnitude, max(high, proposedUpper))
        let domain = min(lower, low)...upper
        var ticks = [domain.lowerBound]
        for index in 1...8 {
            let tick = lower + Double(index) * step
            if tick >= domain.upperBound - step * 0.45 { break }
            ticks.append(tick)
        }
        ticks.append(domain.upperBound)
        return .init(domain: domain, ticks: ticks)
    }
}
