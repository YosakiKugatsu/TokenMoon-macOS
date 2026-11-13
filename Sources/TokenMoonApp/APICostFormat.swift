// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func apiCostLabel(_ value: Double?, compact: Bool = false, missing: String = "—") -> String {
    guard let value else { return missing }
    let label: String
    if compact, let (divisor, suffix) = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        .first(where: { value >= $0.0 }) {
        let scaled = value / divisor
        let digits = scaled < 10 ? 2 : scaled < 100 ? 1 : 0
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits))
            .locale(Locale(identifier: "en_US"))
        label = "$" + scaled.formatted(style) + suffix
    } else if compact, value > 0, value < 0.0001 {
        let style = FloatingPointFormatStyle<Double>.number.notation(.scientific).precision(.significantDigits(1))
            .locale(Locale(identifier: "en_US"))
        label = "$" + value.formatted(style)
    } else {
        let digits = value > 0 && value < 0.01 ? 4...9 : 2...2
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(digits))
            .locale(Locale(identifier: "en_US"))
        label = value.formatted(style)
    }
    return label
}

/// For compact numeric surfaces only. Reports, details and accessible values keep the precise amount.
func roundedUSDCostDigits(_ value: Double?) -> String? {
    guard let value, value.isFinite else { return nil }
    return value.rounded(.toNearestOrAwayFromZero)
        .formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
}
