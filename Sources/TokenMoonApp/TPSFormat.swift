// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import TokenMoonCore

/// A displayed lower bound must not round above the calculated estimate.
func estimatedTPSLabel(_ value: Double?, missing: String = "—", lowerBound: Bool = true) -> String {
    guard let value, value.isFinite, value > 0 else { return missing }
    let digits = value >= 0.1 ? 1 : value >= 0.01 ? 2 : value >= 0.001 ? 3 : 4
    if lowerBound {
        return "≥ " + value.formatted(.number.precision(.fractionLength(digits)).rounded(rule: .down))
    }
    return value.formatted(.number.precision(.fractionLength(digits)))
}

func estimatedTPSLabel(for request: UsageRequest) -> String {
    estimatedTPSLabel(request.estimatedTPS, lowerBound: request.estimatedTPSTiming?.basis != .cpaCompleteRequestFallback)
}

func estimatedTPSLabel(for metrics: UsageMetrics) -> String {
    estimatedTPSLabel(metrics.estimatedTPS, lowerBound: metrics.estimatedTPSFallbackSamples == 0)
}

func estimatedTPSHelp(for request: UsageRequest) -> String {
    if request.estimatedTPSTiming?.basis == .cpaCompleteRequestFallback {
        return "缺少可用日志时间差；使用该 CPA 请求的已测完整耗时计算"
    }
    if request.estimatedTPS != nil { return "输出 Token ÷ 同一次请求的日志时间差，为下限" }
    if request.isFailure { return "请求未成功，未估算 TPS" }
    if request.outputTokens == 0 { return "没有输出 Token，未估算 TPS" }
    if request.estimatedDurationMS == nil { return "缺少可关联的日志时间边界，也没有可用的 CPA 完整耗时" }
    return "这次日志的时间差无法用于估算 TPS"
}

func estimatedTPSHelp(for metrics: UsageMetrics, scope: EstimatedTPSOutputScope? = nil) -> String {
    let samples = scope.map { metrics.estimatedTPSSamples(for: $0) } ?? metrics.estimatedTPSSamples
    let fallback = scope.map { metrics.estimatedTPSFallbackSamples(for: $0) } ?? metrics.estimatedTPSFallbackSamples
    guard samples > 0 else { return "暂无有效计时样本" }
    if fallback > 0 {
        return "累计输出 Token ÷ 累计耗时；缺少日志时使用 CPA 已测完整耗时"
    }
    return "累计输出 Token ÷ 累计日志时间差，为下限"
}
