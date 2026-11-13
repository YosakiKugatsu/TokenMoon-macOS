// SPDX-License-Identifier: GPL-3.0-only
import Charts
import SwiftUI
import TokenMoonCore

/// Model share and hourly activity for the requests listed in a session sheet.
/// The aggregate runs off the main actor and only when the request slice, prices or
/// display calendar change; hover, search and paging never rebuild it.
struct SessionDetailCharts: View {
    let model: AppModel
    let requests: [UsageRequest]

    @State private var loaded: Loaded?
    @State private var basis: ShareBasis = .tokens
    @State private var hovered: HeatCell?
    @State private var activityPage = 0
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Input: Equatable, Sendable {
        let requests: [UsageRequest]
        let costs: [UsageKey: RequestCost]
        let calendar: Calendar

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.calendar == rhs.calendar, lhs.requests == rhs.requests else { return false }
            return lhs.requests.allSatisfy { lhs.costs[$0.key] == rhs.costs[$0.key] }
        }
    }

    private struct Loaded {
        let insights: SessionDetailInsights
        let calendar: Calendar
    }

    private var input: Input {
        // The table prices rows from the same immutable snapshot map.
        Input(requests: requests, costs: model.snapshot?.costs ?? [:], calendar: model.displayCalendar)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                shareCard.frame(width: 330)
                activityCard.frame(minWidth: 360)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                shareCard
                activityCard
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: input) { [input] in
            let worker = Task.detached(priority: .userInitiated) {
                SessionDetailInsights(requests: input.requests, costs: input.costs, calendar: input.calendar)
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            hovered = nil
            activityPage = min(activityPage, pageCount(for: next.activityDays.count) - 1)
            loaded = Loaded(insights: next, calendar: input.calendar)
        }
    }

    private func card<Accessory: View, Content: View>(_ title: String, @ViewBuilder accessory: () -> Accessory,
                                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                accessory()
            }
            .frame(minHeight: 22)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.quinary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.32 : 0.11))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Model share

    private enum ShareBasis: String, CaseIterable, Identifiable {
        case tokens, cost
        var id: Self { self }
        var label: String { self == .tokens ? "Token" : "计费" }
    }

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let value: Double
        let share: Double
        let amount: String
        let color: Color

        var percent: String {
            let value = share * 100
            return value > 0 && value < 1 ? "<1%" : value.formatted(.number.precision(.fractionLength(0))) + "%"
        }
    }

    private static let shareLimit = 5

    private var shareCard: some View {
        card("模型占比") {
            Picker("占比口径", selection: $basis) {
                ForEach(ShareBasis.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("按 Token 用量或等效费用计算占比")
            .accessibilityLabel("模型占比口径")
        } content: {
            if let insights = loaded?.insights {
                shareContent(insights)
            } else {
                loading(height: Self.donutSize)
            }
        }
    }

    @ViewBuilder private func shareContent(_ insights: SessionDetailInsights) -> some View {
        let slices = slices(insights)
        let unpriced = insights.models.reduce(0) { $0 + $1.unpricedRequests }
        if slices.isEmpty {
            Text(insights.models.isEmpty ? "此会话暂无请求" :
                    basis == .tokens ? "暂无 Token 用量" : "暂无已计价费用")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.donutSize)
        } else {
            HStack(alignment: .center, spacing: 12) {
                donut(slices)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(slices) { slice in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(slice.color).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(verbatim: slice.name).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: slice.percent).monospacedDigit().fixedSize()
                        }
                        .font(.caption)
                        .help("\(slice.name)\n\(slice.amount) · \(slice.percent)")
                    }
                    if basis == .cost && unpriced > 0 {
                        Text("\(unpriced.formatted()) 次请求未计价").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("模型占比，按\(basis.label)")
            .accessibilityValue(slices.map { "\($0.name) \($0.percent)，\($0.amount)" }.joined(separator: "；")
                + (basis == .cost && unpriced > 0 ? "；\(unpriced) 次请求未计价" : ""))
        }
    }

    private static let donutSize: CGFloat = 112

    private func donut(_ slices: [Slice]) -> some View {
        var total = 0.0
        for slice in slices { total += slice.value }
        let centerLabel = basis == .tokens
            ? compactTokenCount(Int64(exactly: total.rounded()) ?? .max)
            : apiCostLabel(total, compact: true)
        return Chart(slices) { slice in
            SectorMark(angle: .value(basis.label, slice.value), innerRadius: .ratio(0.62), angularInset: 1)
                .foregroundStyle(slice.color)
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let plot = geometry[frame]
                    Text(verbatim: centerLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: plot.width * 0.56)
                        .position(x: plot.midX, y: plot.midY)
                }
            }
        }
        .frame(width: Self.donutSize, height: Self.donutSize)
        .accessibilityHidden(true)
    }

    private func slices(_ insights: SessionDetailInsights) -> [Slice] {
        typealias Weighted = (row: SessionDetailInsights.Model, value: Double)
        let byTokens = basis == .tokens
        var weighted: [Weighted] = []
        for row in insights.models {
            let value: Double = byTokens ? Double(row.tokens) : max(0, row.costUSD ?? 0)
            if value > 0 { weighted.append((row: row, value: value)) }
        }
        weighted.sort { (a: Weighted, b: Weighted) -> Bool in
            a.value == b.value ? a.row.id < b.row.id : a.value > b.value
        }
        var total = 0.0
        for entry in weighted { total += entry.value }
        guard total > 0 else { return [] }
        let head = weighted.count <= Self.shareLimit ? weighted.count : Self.shareLimit - 1
        let heads: [Weighted] = Array(weighted.prefix(head))
        let colors = sliceColors(heads.map { (entry: Weighted) -> String in entry.row.id })
        var result: [Slice] = []
        for (index, entry) in heads.enumerated() {
            let id = entry.row.id
            let name = id == "unknown" ? "未知模型" : model.modelDisplayName(id)
            result.append(Slice(id: id, name: name, value: entry.value, share: entry.value / total,
                                amount: amount(entry.value), color: colors[index]))
        }
        if weighted.count > head {
            var rest = 0.0
            for entry in weighted.dropFirst(head) { rest += entry.value }
            result.append(Slice(id: "\u{0}other", name: "其他（\(weighted.count - head)）", value: rest,
                                share: rest / total, amount: amount(rest), color: .secondary.opacity(0.55)))
        }
        return result
    }

    /// Reuses each model's chart color; models without one take free palette slots.
    private func sliceColors(_ ids: [String]) -> [Color] {
        let slots = model.modelColorSlots
        var used = Set(ids.compactMap { slots[$0] })
        var next = 0
        return ids.map { id in
            if let slot = slots[id] { return ModelChartPalette.color(slot: slot) }
            while used.contains(next) { next += 1 }
            used.insert(next)
            return ModelChartPalette.color(slot: next)
        }
    }

    private func amount(_ value: Double) -> String {
        basis == .tokens ? "\(compactTokenCount(Int64(exactly: value.rounded()) ?? .max)) Token" : apiCostLabel(value)
    }

    // MARK: - Activity heatmap

    private struct HeatCell: Equatable {
        let day: Date
        let hour: Int
        let requests: Int
    }

    /// Paged, not scrolled: even a long-running session stays within the sheet.
    private static let maxDays = 31

    private func pageCount(for days: Int) -> Int { max(1, (days + Self.maxDays - 1) / Self.maxDays) }

    private var activityCard: some View {
        card("活跃热力图") {
            HStack(spacing: 5) {
                Text(verbatim: activityCaption)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                if let loaded {
                    let count = pageCount(for: loaded.insights.activityDays.count)
                    if count > 1 {
                        let page = min(activityPage, count - 1)
                        Button("更早的活跃记录", systemImage: "chevron.left") {
                            hovered = nil
                            activityPage = min(page + 1, count - 1)
                        }
                        .disabled(page >= count - 1)
                        Text("\(count - page)/\(count)").font(.caption2.monospacedDigit())
                        Button("更新的活跃记录", systemImage: "chevron.right") {
                            hovered = nil
                            activityPage = max(page - 1, 0)
                        }
                        .disabled(page == 0)
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } content: {
            if let loaded {
                if loaded.insights.activityDays.isEmpty {
                    Text("此会话暂无请求").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    heatmap(loaded)
                }
            } else {
                loading(height: 60)
            }
        }
    }

    private var activityCaption: String {
        guard let loaded else { return "" }
        let calendar = loaded.calendar
        if let hovered {
            return dayLabel(hovered.day, calendar: calendar) + " " + hourSpan(hovered.hour) + " · \(hovered.requests) 次请求"
        }
        return "峰值 \(loaded.insights.activityPeak) 次/小时"
    }

    private func heatmap(_ loaded: Loaded) -> some View {
        let allDays = loaded.insights.activityDays
        let page = min(activityPage, pageCount(for: allDays.count) - 1)
        let end = allDays.count - page * Self.maxDays
        let days = Array(allDays[max(0, end - Self.maxDays)..<end])
        let peak = max(1, loaded.insights.activityPeak)
        let calendar = loaded.calendar
        let gap: CGFloat = days.count > 14 ? 1 : 2
        let rowHeight: CGFloat = days.count == 1 ? 18
            : min(16, max(3, ((112 - gap * CGFloat(days.count - 1)) / CGFloat(days.count)).rounded(.down)))
        let gridHeight = rowHeight * CGFloat(days.count) + gap * CGFloat(days.count - 1)
        let labelWidth: CGFloat = 52
        let empty = Color.primary.opacity(contrast == .increased ? 0.16 : 0.07)
        let fill = Color.accentColor
        let tz = calendar.timeZone.abbreviation() ?? calendar.timeZone.identifier

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                dayLabels(days, rowHeight: rowHeight, gap: gap, calendar: calendar)
                    .frame(width: labelWidth, height: gridHeight, alignment: .topLeading)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let column = (width - gap * 23) / 24
                    Canvas { context, _ in
                        for (row, day) in days.enumerated() {
                            let y = CGFloat(row) * (rowHeight + gap)
                            for hour in 0..<24 {
                                let count = day.hours.indices.contains(hour) ? day.hours[hour] : 0
                                let rect = CGRect(x: CGFloat(hour) * (column + gap), y: y, width: column, height: rowHeight)
                                let color = count == 0 ? empty : fill.opacity(0.28 + 0.72 * Double(count) / Double(peak))
                                context.fill(Path(roundedRect: rect, cornerRadius: min(2, rowHeight / 3)), with: .color(color))
                            }
                        }
                        if let hovered, let row = days.firstIndex(where: { $0.id == hovered.day }) {
                            let rect = CGRect(x: CGFloat(hovered.hour) * (column + gap), y: CGFloat(row) * (rowHeight + gap),
                                              width: column, height: rowHeight)
                            context.stroke(Path(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 2),
                                           with: .color(.primary.opacity(0.8)), lineWidth: 1)
                        }
                    }
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        guard case let .active(point) = phase, column > 0 else { hovered = nil; return }
                        let hour = Int(point.x / (column + gap)), row = Int(point.y / (rowHeight + gap))
                        guard (0..<24).contains(hour), days.indices.contains(row) else { hovered = nil; return }
                        let day = days[row]
                        let next = HeatCell(day: day.id, hour: hour, requests: day.hours.indices.contains(hour) ? day.hours[hour] : 0)
                        if hovered != next { hovered = next }
                    }
                }
                .frame(height: gridHeight)
            }
            hourAxis(leading: labelWidth + 6, gap: gap)
        }
        .help("按显示时区（\(tz)）统计每小时的请求次数；颜色越深请求越多")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("会话活动热力图，显示时区 \(tz)")
        .accessibilityValue(activitySummary(days, peak: loaded.insights.activityPeak, calendar: calendar))
    }

    @ViewBuilder private func dayLabels(_ days: [SessionDetailInsights.Day], rowHeight: CGFloat,
                                        gap: CGFloat, calendar: Calendar) -> some View {
        if rowHeight >= 11 {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(days) { day in
                    Text(verbatim: dayLabel(day.id, calendar: calendar))
                        .frame(height: rowHeight)
                }
            }
            .font(.system(size: min(10, rowHeight - 1)).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let first = days.first, let last = days.last {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: dayLabel(first.id, calendar: calendar))
                Spacer(minLength: 0)
                Text(verbatim: dayLabel(last.id, calendar: calendar))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func hourAxis(leading: CGFloat, gap: CGFloat) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width - leading
            let column = (width - gap * 23) / 24
            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                let x = leading + (hour == 24 ? width : CGFloat(hour) * (column + gap))
                Text(verbatim: "\(hour)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(x, leading + 4), geometry.size.width - 6), y: 6)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func activitySummary(_ days: [SessionDetailInsights.Day], peak: Int, calendar: Calendar) -> String {
        let active = days.filter { $0.requests > 0 }
        let perDay = active.map { day -> String in
            let busiest = day.hours.indices.max { day.hours[$0] < day.hours[$1] } ?? 0
            return "\(dayLabel(day.id, calendar: calendar)) \(day.requests) 次，高峰 \(hourSpan(busiest)) \(day.hours[busiest]) 次"
        }
        return (["\(days.count) 天，峰值每小时 \(peak) 次"] + perDay).joined(separator: "；")
    }

    private func dayLabel(_ day: Date, calendar: Calendar) -> String {
        UsageDisplayTime.format(day, as: .dateTime.month().day().locale(Locale(identifier: "zh_CN")), calendar: calendar)
    }

    private func hourSpan(_ hour: Int) -> String {
        String(format: "%02d:00–%02d:00", hour, hour + 1)
    }

    private func loading(height: CGFloat) -> some View {
        ProgressView().controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: height)
            .accessibilityLabel("正在汇总")
    }
}
