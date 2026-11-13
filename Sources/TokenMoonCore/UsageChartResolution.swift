// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum UsageChartResolution {
    public static let defaultBucketCount = UsageBucketInterval.defaultTargetBucketCount

    /// Use the available content width, reserving space for axis labels and
    /// enough room for each stacked column. Quantize during live resize.
    public static func targetBucketCount(forContentWidth width: Double) -> Int {
        guard width.isFinite, width > 0 else { return defaultBucketCount }
        let estimated = min(72, max(12, (width - 48) / 20))
        return Int(estimated) / 4 * 4
    }
}
