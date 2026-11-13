// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Token counts read the same in the menu bar, popup, dashboard and session table:
/// three significant digits with an English suffix. Thresholds sit on the rounding
/// points, so 99,960 reads "100K" and 999,600 "1.00M", never "100.0K" or "1000K".
func compactTokenCount(_ value: Int64) -> String {
    let v = Double(value)
    for (limit, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= limit * 0.9995 {
        let scaled = v / limit
        return String(format: scaled < 9.995 ? "%.2f" : scaled < 99.95 ? "%.1f" : "%.0f", scaled) + suffix
    }
    return "\(value)"
}

/// Chart ticks may round harder than values so a narrow axis never crowds, but they
/// keep the same English suffixes whatever the process locale is.
func compactAxisCount(_ value: Double) -> String {
    value.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US")))
}
