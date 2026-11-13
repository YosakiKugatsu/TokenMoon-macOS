// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

/// The cycle already carries observed model cost totals; the hover card only
/// formats them and combines the small slices into a single remainder.
struct CycleModelCostShare: View {
    private struct Slice: Identifiable {
        let id: Int
        let name: String
        let share: Double
        let percentage: Int
        let color: Color

        var percent: String { percentage == 0 ? "<1%" : "\(percentage)%" }
    }

    private static let palette: [UInt32] = [0x7AA2F7, 0x9ECE6A, 0xE0AF68, 0xBB9AF7, 0xF7768E]
    private let slices: [Slice]
    private let totalUSD: Double?
    private let modelCount: Int
    let stacked: Bool

    init(_ rows: [UsageQuotaInsights.ModelCostShare], stacked: Bool) {
        self.stacked = stacked
        modelCount = rows.count
        let total = rows.reduce(Int64(0)) { sum, row in
            let (value, overflow) = sum.addingReportingOverflow(row.costNanos)
            return overflow ? .max : value
        }
        self.totalUSD = total > 0 ? Double(total) / 1_000_000_000 : nil
        let denominator = rows.reduce(0.0) { $0 + Double($1.costNanos) }
        guard denominator > 0 else { slices = []; return }
        let limit = rows.count <= 5 ? rows.count : 4
        let heads = rows.prefix(limit)
        var names = heads.map { $0.model == "unknown" ? "未知模型" : $0.model }
        var weights = heads.map { Double($0.costNanos) }
        if rows.count > limit {
            names.append("其他（\(rows.count - limit)）")
            weights.append(rows.dropFirst(limit).reduce(0) { $0 + Double($1.costNanos) })
        }
        let shares = weights.map { $0 / denominator }
        let rounded = Self.roundedPercentages(shares)
        slices = shares.indices.map { index in
            let isRemainder = index >= limit
            return Slice(id: index, name: names[index], share: shares[index], percentage: rounded[index],
                         color: Self.color(isRemainder ? 0x5C6370 : Self.palette[index]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("模型费用占比（\(modelCount)）").font(.caption.weight(.semibold))
            HStack(spacing: 10) {
                ring
                if !slices.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(slices) { slice in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(slice.color).frame(width: 8, height: 8)
                                Text(verbatim: slice.name)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: slice.percent).monospacedDigit().fixedSize()
                            }
                            .font(.caption2)
                            .frame(height: 18)
                        }
                    }
                } else {
                    Text("暂无已计价费用").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    var accessibilitySummary: String {
        slices.isEmpty ? "模型费用占比，暂无已计价费用" :
            "模型费用占比，已观测费用合计 \(apiCostLabel(totalUSD))：" +
            slices.map { "\($0.name) \($0.percent)" }.joined(separator: "，")
    }

    private var ring: some View {
        let diameter: CGFloat = stacked ? 88 : 64
        return ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 1
                let inner = radius * 0.60
                var track = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                track.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
                if slices.count < 2 {
                    context.fill(track, with: .color(slices.first?.color ?? Self.color(0x2A2F3A)),
                                 style: FillStyle(eoFill: true))
                } else {
                    let divider = Color(nsColor: .textBackgroundColor)
                    var angle = -Double.pi / 2
                    for slice in slices {
                        let end = angle + slice.share * 2 * .pi
                        var wedge = Path()
                        wedge.addArc(center: center, radius: radius, startAngle: .radians(angle),
                                     endAngle: .radians(end), clockwise: false)
                        wedge.addArc(center: center, radius: inner, startAngle: .radians(end),
                                     endAngle: .radians(angle), clockwise: true)
                        wedge.closeSubpath()
                        context.fill(wedge, with: .color(slice.color))
                        context.stroke(wedge, with: .color(divider), lineWidth: 1)
                        angle = end
                    }
                }
            }
            Text(verbatim: ringAmount)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.72)
                .frame(width: (diameter - 4) * 0.60)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private var ringAmount: String {
        guard let totalUSD else { return "—" }
        if totalUSD < 0.01 { return "<$0.01" }
        if (100..<1000).contains(totalUSD) {
            return "$" + totalUSD.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
        }
        return apiCostLabel(totalUSD, compact: true)
    }

    /// Largest remainders receive the spare points, ties stay in model order.
    private static func roundedPercentages(_ shares: [Double]) -> [Int] {
        let raw = shares.map { $0 * 100 }
        var values = raw.map { Int($0.rounded(.down)) }
        let order = values.indices.sorted {
            let left = raw[$0] - Double(values[$0]), right = raw[$1] - Double(values[$1])
            return left == right ? $0 < $1 : left > right
        }
        for index in order.prefix(max(0, 100 - values.reduce(0, +))) {
            values[index] += 1
        }
        return values
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
