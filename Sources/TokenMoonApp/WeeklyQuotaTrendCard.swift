// SPDX-License-Identifier: GPL-3.0-only
import Charts
import SwiftUI
import TokenMoonCore

struct WeeklyQuotaTrendCard: View {
    let model: AppModel
    @Binding var selection: String
    let option: QuotaDepletionOption?
    @Environment(\.colorSchemeContrast) private var contrast

    private var chart: QuotaDepletionChart? {
        guard let chart = model.quotaDepletionChart, chart.seriesID == option?.id else { return nil }
        return chart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    heading.fixedSize()
                    Spacer(minLength: 0)
                    accountPicker
                }
                VStack(alignment: .leading, spacing: 8) { heading; accountPicker }
            }
            if let chart, !chart.readings.isEmpty || chart.requests > 0 {
                WeeklyQuotaPlot(data: .init(chart), model: model)
                    .id(chart.seriesID)
            } else if model.isQuotaDepletionChartLoading {
                ProgressView("正在读取额度与费用")
                    .frame(maxWidth: .infinity).frame(height: 280)
            } else {
                ContentUnavailableView("此范围内没有额度读数或费用", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity).frame(height: 280)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Int.self) { geometry in
            UsageChartResolution.targetBucketCount(forContentWidth: Double(geometry.size.width))
        } action: { model.setChartBucketTarget($0) }
        .padding(18)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.32 : 0.11))
                .allowsHitTesting(false)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("周额度与等效费用").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(caption).font(.callout).foregroundStyle(Color.primary.opacity(contrast == .increased ? 1 : 0.77))
        }
        .help("费用包含同供应商、同官方账号的全部设备，含已确认的历史账号归属。上游 API Key 不计入。未知费用与 $0 分开显示。")
    }

    private var caption: String {
        let book = model.priceSource == .omc ? "OMC 价目" : "公开价目"
        return [model.range.label, (chart?.interval ?? model.timelineInterval).label,
                "同账号全部设备", "不受模型/设备筛选", book,
                option?.partialHistory == true ? "部分历史无法追溯" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var accountPicker: some View {
        Menu {
            Button { selection = "" } label: {
                if selection.isEmpty { Label("自动（降幅最大）", systemImage: "checkmark") }
                else { Text("自动（降幅最大）") }
            }
            Divider()
            ForEach(model.quotaDepletionOptions) { item in
                Button { selection = item.id } label: {
                    if selection == item.id { Label(item.title, systemImage: "checkmark") }
                    else { Text(item.title) }
                }
            }
        } label: {
            Text(option.map { selection.isEmpty ? "自动 · " + $0.title : $0.title } ?? "自动（降幅最大）")
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .menuStyle(.button).buttonStyle(.bordered)
        .focusEffectDisabled()
        .disabled(model.quotaDepletionOptions.isEmpty)
        .accessibilityLabel("切换额度账号")
        .accessibilityValue(option?.title ?? "自动")
        .help(option?.title ?? "选择周额度账号")
    }
}

private struct WeeklyQuotaPlotData {
    struct Point: Identifiable {
        let reading: QuotaDepletionChart.Reading
        let line: Int
        let correction: Bool
        var id: Date { reading.at }
    }

    let chart: QuotaDepletionChart
    let maximum: Double
    let points: [Point]
    let resets: [Date]
    let hasKnownCost: Bool
    let axisDates: [Date]

    init(_ chart: QuotaDepletionChart) {
        self.chart = chart
        hasKnownCost = chart.buckets.contains { $0.costUSD != nil }
        let axisStep = max(1, (chart.buckets.count + 2) / 4)
        axisDates = stride(from: 0, to: chart.buckets.count, by: axisStep)
            .map { chart.buckets[$0].bounds.lowerBound }
        let peak = chart.buckets.compactMap(\.costUSD).max() ?? 0
        let needsCapRoom = peak > 0 && chart.buckets.contains { $0.costUSD == peak && $0.unpricedRequests > 0 }
        let headroom = needsCapRoom ? peak / 0.94 : peak
        if headroom > 0 && headroom.isFinite {
            let unit = pow(10, floor(log10(headroom)))
            maximum = ([1.0, 2, 4, 5, 10].first { $0 * unit >= headroom } ?? 10) * unit
        } else {
            maximum = 1
        }

        var points: [Point] = []
        var resets: Set<Date> = []
        var previous: QuotaDepletionChart.Reading?
        var previousPosition: Double?
        var line = 0
        for reading in chart.readings {
            let position = Self.bucketIndex(at: reading.at, in: chart.buckets).map { index in
                let bounds = chart.buckets[index].bounds
                return Double(index) + reading.at.timeIntervalSince(bounds.lowerBound)
                    / bounds.upperBound.timeIntervalSince(bounds.lowerBound)
            }
            var correction = false
            if let previous {
                let separated = previous.segment != reading.segment
                let gap = if let previousPosition, let position { position - previousPosition > 3 } else { false }
                if separated || gap { line += 1 }
                if separated {
                    let newStart = reading.resetsAt?.addingTimeInterval(-QuotaDepletion.weeklySeconds)
                    if let oldReset = previous.resetsAt, let newStart, newStart <= reading.at,
                       reading.at >= oldReset || (newStart >= previous.at && previous.remainingPercent < 100) {
                        let boundary = newStart > previous.at ? newStart : oldReset
                        if chart.bounds.contains(boundary), boundary <= reading.at { resets.insert(boundary) }
                    } else if reading.remainingPercent > previous.remainingPercent,
                              reading.resetsAt != nil, previous.resetsAt != nil {
                        correction = true
                    }
                }
            }
            points.append(.init(reading: reading, line: line, correction: correction))
            previous = reading
            previousPosition = position
        }
        self.points = points
        self.resets = resets.sorted()
    }

    func index(at time: Date?) -> Int? {
        time.flatMap { Self.bucketIndex(at: $0, in: chart.buckets) }
    }

    func percent(for cost: Double?) -> Double { min(100, max(0, (cost ?? 0) / maximum * 100)) }

    private static func bucketIndex(at time: Date, in buckets: [QuotaDepletionChart.Bucket]) -> Int? {
        var first = 0, last = buckets.count
        while first < last {
            let middle = (first + last) / 2
            if buckets[middle].bounds.upperBound <= time { first = middle + 1 }
            else { last = middle }
        }
        return first < buckets.count && buckets[first].bounds.contains(time) ? first : nil
    }
}

private struct WeeklyQuotaPlot: View {
    let data: WeeklyQuotaPlotData
    let model: AppModel
    @State private var hovered: Date?
    @State private var pinned: Date?
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var appearance

    private let ticks: [Double] = [0, 25, 50, 75, 100]
    private var ink: Color { .primary.opacity(contrast == .increased ? 1 : 0.77) }
    private var lineColor: Color {
        contrast == .increased ? (appearance == .dark ? Color(red: 0.38, green: 0.88, blue: 0.92) : Color(red: 0.05, green: 0.39, blue: 0.45))
            : ModelChartPalette.color(slot: 5)
    }
    private var fillColor: Color { .primary.opacity(contrast == .increased ? 0.30 : 0.16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                axisTitle("剩余额度", symbol: "circle.fill", color: lineColor)
                Spacer(minLength: 0)
                axisTitle(data.hasKnownCost ? "等效费用 (USD)" : "等效费用 未知", symbol: "rectangle.portrait.fill", color: ink.opacity(0.65))
            }
            chart
                .frame(height: 255)
        }
        .onChange(of: model.range) { clearSelection() }
        .onChange(of: model.customHours) { clearSelection() }
        .onChange(of: model.displayTimeZone.identifier) { clearSelection() }
        .onChange(of: data.chart.interval) { clearSelection() }
    }

    private func axisTitle(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 7)).foregroundStyle(color).accessibilityHidden(true)
            Text(title).foregroundStyle(ink)
        }
        .font(.caption)
    }

    private var chart: some View {
        let hovering = data.index(at: hovered)
        let fixed = data.index(at: pinned)
        return Chart {
            costMarks
            resetMarks
            readingMarks
            if let fixed, fixed != hovering {
                selectionMark(index: fixed, hovering: false)
            }
            if let hovering {
                selectionMark(index: hovering, hovering: true)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(for: data.chart.buckets[hovering])
                    }
            }
        }
        .chartXScale(domain: data.chart.bounds.lowerBound...data.chart.bounds.upperBound, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0.0...100.0)
        .chartXAxis {
            AxisMarks(values: data.axisDates) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            }
        }
        .chartYAxis { yAxes }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = chartDate(at: point, proxy: proxy, geometry: geometry)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        focused = true
                        let index = data.index(at: chartDate(at: point, proxy: proxy, geometry: geometry))
                        pinned = index == fixed ? nil : index.map { midpoint(data.chart.buckets[$0]) }
                    }
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    costOutlines(proxy: proxy, plot: plot)
                    timeLabels(proxy: proxy, plot: plot, width: geometry.size.width)
                    if data.points.isEmpty {
                        Text("此范围无官方额度读数")
                            .font(.caption).foregroundStyle(ink)
                            .padding(4)
                            .offset(x: plot.minX, y: plot.minY + 3)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .environment(\.timeZone, model.displayTimeZone)
        .accessibilityLabel("周额度与等效费用趋势")
        .accessibilityHint("方向键固定时段，按 Escape 取消固定")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) {
            guard pinned != nil else { return .ignored }
            pinned = nil
            return .handled
        }
        .padding(.bottom, 18)
    }

    @ChartContentBuilder private var costMarks: some ChartContent {
        ForEach(data.chart.buckets) { bucket in
            if let value = bucket.costUSD, value > 0 {
                RectangleMark(xStart: .value("时段起点", bucket.bounds.lowerBound),
                              xEnd: .value("时段终点", bucket.bounds.upperBound),
                              yStart: .value("等效费用", 0.0), yEnd: .value("等效费用", data.percent(for: value)))
                    .cornerRadius(2)
                    .foregroundStyle(fillColor)
                    .accessibilityLabel(bucketTitle(bucket))
                    .accessibilityValue(feeLabel(bucket))
            } else if bucket.unpricedRequests > 0 {
                RectangleMark(xStart: .value("时段起点", bucket.bounds.lowerBound),
                              xEnd: .value("时段终点", bucket.bounds.upperBound),
                              yStart: .value("等效费用", 0.0), yEnd: .value("等效费用", 6.0))
                    .foregroundStyle(Color.clear)
                    .accessibilityLabel(bucketTitle(bucket))
                    .accessibilityValue(feeLabel(bucket))
            }
        }
    }

    @ChartContentBuilder private var resetMarks: some ChartContent {
        ForEach(data.resets, id: \.self) { date in
            RuleMark(x: .value("重置", date))
                .foregroundStyle(Color.primary.opacity(0.25))
                .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                .accessibilityHidden(true)
                .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    Text("重置").font(.caption2).foregroundStyle(ink)
                }
        }
    }

    @ChartContentBuilder private var readingMarks: some ChartContent {
        ForEach(data.points) { point in
            let reading = point.reading
            LineMark(x: .value("观测时间", reading.at), y: .value("剩余额度", reading.remainingPercent),
                     series: .value("连续观测", point.line))
                .foregroundStyle(lineColor)
                .lineStyle(.init(lineWidth: 1.75, lineCap: .round))
                .interpolationMethod(.linear)
                .accessibilityHidden(true)
            PointMark(x: .value("观测时间", reading.at), y: .value("剩余额度", reading.remainingPercent))
                .foregroundStyle(lineColor)
                .symbol {
                    if point.correction {
                        Circle().strokeBorder(lineColor, lineWidth: 1.2).frame(width: 6, height: 6)
                    } else {
                        Circle().fill(lineColor).frame(width: 4, height: 4)
                    }
                }
                .accessibilityLabel(dateLabel(reading.at))
                .accessibilityValue(percentLabel(reading.remainingPercent))
        }
    }

    private func selectionMark(index: Int, hovering: Bool) -> some ChartContent {
        RuleMark(x: .value("选中时段", midpoint(data.chart.buckets[index])))
            .foregroundStyle(Color.primary.opacity(hovering ? 0.45 : 0.28))
            .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
            .accessibilityHidden(true)
    }

    private func timeLabels(proxy: ChartProxy, plot: CGRect, width: CGFloat) -> some View {
        ForEach(data.axisDates, id: \.self) { date in
            if let x = proxy.position(forX: date) {
                let label = axisDate(date)
                let halfWidth = CGFloat(label.count) * 3.5 + 3
                Text(label).font(.caption2.monospacedDigit()).foregroundStyle(ink)
                    .fixedSize()
                    .position(x: min(max(plot.minX + x, halfWidth), width - halfWidth), y: plot.maxY + 11)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @AxisContentBuilder private var yAxes: some AxisContent {
        AxisMarks(position: .leading, values: ticks) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            AxisValueLabel {
                if let percent = value.as(Double.self) { Text("\(Int(percent))%").monospacedDigit().foregroundStyle(ink) }
            }
        }
        if data.hasKnownCost {
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(percent == 0 ? "$0" : apiCostLabel(data.maximum * percent / 100, compact: true))
                            .monospacedDigit().foregroundStyle(ink)
                    }
                }
            }
        }
    }

    private func costOutlines(proxy: ChartProxy, plot: CGRect) -> some View {
        let increased = contrast == .increased
        let color = Color.primary.opacity(increased ? 0.75 : 0.40)
        let outlines: [(CGRect, Bool)] = data.chart.buckets.flatMap { bucket -> [(CGRect, Bool)] in
            guard increased || bucket.unpricedRequests > 0,
                  let x0 = proxy.position(forX: bucket.bounds.lowerBound),
                  let x1 = proxy.position(forX: bucket.bounds.upperBound), x1 - x0 > 1 else { return [] }
            let height = data.percent(for: bucket.costUSD)
            func outline(_ lower: Double, _ upper: Double, dashed: Bool) -> (CGRect, Bool)? {
                guard upper > lower, let top = proxy.position(forY: upper),
                      let bottom = proxy.position(forY: lower), bottom - top > 0.7 else { return nil }
                let rect = CGRect(x: plot.minX + x0, y: plot.minY + top, width: x1 - x0, height: bottom - top)
                    .insetBy(dx: 0.35, dy: 0.35)
                return (rect, dashed)
            }
            return [
                increased ? outline(0, height, dashed: false) : nil,
                bucket.unpricedRequests > 0 ? outline(height, min(100, height + 6), dashed: true) : nil,
            ].compactMap { $0 }
        }
        return Canvas { context, _ in
            for (rect, dashed) in outlines {
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color),
                               style: .init(lineWidth: dashed ? 0.75 : 0.5, dash: dashed ? [2, 2] : []))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tooltip(for bucket: QuotaDepletionChart.Bucket) -> some View {
        let readings = data.points.filter { bucket.bounds.contains($0.reading.at) }.reversed()
        let entries = readings.prefix(5).map { point in
            ChartValueTip.Entry(id: String(point.reading.at.timeIntervalSinceReferenceDate),
                name: point.correction ? "修正后" : "剩余额度",
                value: "\(percentLabel(point.reading.remainingPercent)) · \(clock(point.reading.at)) 观测", color: lineColor)
        }
        let reset = data.resets.last { bucket.bounds.contains($0) }.map { "重置 " + clock($0) }
        let note = ["\(bucket.requests.formatted()) 次请求", reset].compactMap { $0 }.joined(separator: " · ")
        return ChartValueTip(title: bucketTitle(bucket), value: feeLabel(bucket), note: note, entries: entries,
                             additionalCount: max(0, readings.count - entries.count))
            .allowsHitTesting(false)
    }

    private func feeLabel(_ bucket: QuotaDepletionChart.Bucket) -> String {
        if bucket.requests == 0 { return "无匹配请求" }
        let value = apiCostLabel(bucket.costUSD, missing: "未知")
        guard bucket.unpricedRequests > 0 else { return value }
        return (bucket.costUSD == nil ? value : "≥ " + value) + " · \(bucket.unpricedRequests.formatted()) 次未计价"
    }

    private func midpoint(_ bucket: QuotaDepletionChart.Bucket) -> Date {
        bucket.bounds.lowerBound.addingTimeInterval(bucket.bounds.upperBound.timeIntervalSince(bucket.bounds.lowerBound) / 2)
    }

    private func chartDate(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]
        guard plot.contains(point) else { return nil }
        return proxy.value(atX: point.x - plot.minX, as: Date.self)
    }

    private func step(_ direction: Int) {
        let buckets = data.chart.buckets
        guard !buckets.isEmpty else { return }
        let index = data.index(at: pinned) ?? data.index(at: hovered) ?? (direction > 0 ? -1 : buckets.count)
        pinned = midpoint(buckets[max(0, min(buckets.count - 1, index + direction))])
    }

    private func clearSelection() { hovered = nil; pinned = nil }

    private func percentLabel(_ percent: Double) -> String {
        (percent / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    private func clock(_ date: Date) -> String {
        let parts = model.displayCalendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func day(_ date: Date) -> String {
        model.formatDate(date, as: .dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }

    private func dateLabel(_ date: Date) -> String { day(date) + " " + clock(date) }

    private func axisDate(_ date: Date) -> String {
        let calendar = model.displayCalendar
        let parts = calendar.dateComponents([.month, .day], from: date)
        let shortDay = "\(parts.month ?? 1)/\(parts.day ?? 1)"
        switch data.chart.interval {
        case .hour, .hours:
            return calendar.isDate(data.chart.bounds.lowerBound, inSameDayAs: data.chart.bounds.upperBound)
                ? clock(date) : shortDay + " " + clock(date)
        case .day, .days, .week: return shortDay
        case .month, .quarter: return model.formatDate(date, as: .dateTime.year().month().locale(Locale(identifier: "zh_CN")))
        case .year: return model.formatDate(date, as: .dateTime.year().locale(Locale(identifier: "zh_CN")))
        }
    }

    private func bucketTitle(_ bucket: QuotaDepletionChart.Bucket) -> String {
        let start = bucket.bounds.lowerBound, end = bucket.bounds.upperBound
        return dateLabel(start) + "–" + (model.displayCalendar.isDate(start, inSameDayAs: end) ? clock(end) : dateLabel(end))
    }
}
