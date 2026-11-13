// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import TokenMoonCore

/// A value shown in either of the menu bar's two usage slots.
enum MenuBarUsageMetric: String, CaseIterable {
    case tokens, cost, requests, cacheHit, estimatedTPS

    var label: String {
        switch self {
        case .tokens: "Token"
        case .cost: "等效费用"
        case .requests: "请求次数"
        case .cacheHit: "缓存命中率"
        case .estimatedTPS: "估算 TPS"
        }
    }

    func readout(for metrics: UsageMetrics) -> MoonStatusGlyph.Metric {
        switch self {
        case .tokens: .init(title: "Token", value: compactTokenCount(metrics.tokens))
        case .cost: .init(title: "Cost", value: roundedUSDCostDigits(metrics.cost).map { $0 + "$" } ?? "—")
        case .requests: .init(title: "Req", value: compactTokenCount(Int64(metrics.requests)))
        case .cacheHit: .init(title: "Cache", value: Self.cacheReadout(metrics.cacheRate))
        case .estimatedTPS: .init(title: "Est. TPS", value: estimatedTPSLabel(for: metrics))
        }
    }

    func accessibilityValue(for metrics: UsageMetrics) -> String {
        switch self {
        case .tokens:
            "token usage: \(metrics.tokens.formatted())"
        case .cost:
            "equivalent cost: \(apiCostLabel(metrics.cost, missing: "unknown"))"
                + (metrics.unpricedRequests > 0 ? ", some requests are unpriced" : "")
        case .requests:
            "requests: \(metrics.requests.formatted())"
        case .cacheHit:
            "cache hit rate: \(Self.cacheReadout(metrics.cacheRate, missing: "unknown"))"
        case .estimatedTPS:
            "estimated TPS: " + estimatedTPSLabel(metrics.estimatedTPS, missing: "unknown",
                                                   lowerBound: metrics.estimatedTPSFallbackSamples == 0)
        }
    }

    private static func cacheReadout(_ rate: Double?, missing: String = "—") -> String {
        rate.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? missing
    }
}
