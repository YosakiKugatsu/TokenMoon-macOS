// SPDX-License-Identifier: GPL-3.0-only
import Charts
import SwiftUI
import TokenMoonCore

/// The native view prices the same saved observations and request ledger as the web view.
struct SubscriptionInsightsView: View {
    private typealias Provider = UsageQuotaInsights.Provider
    private struct Drag {
        let agent: Provider
        let point: CGPoint
    }

    let model: AppModel
    var scrollNearEdge: (CGPoint) -> Void = { _ in }
    var showOfficial: (String) -> Void
    @State private var frames: [Provider: CGRect] = [:]
    @State private var drag: Drag?

    var body: some View {
        let byAgent = Dictionary(grouping: model.subscriptionUsageEstimates, by: \.provider)
        let agents = SubscriptionAgentOrder.visible(saved: model.subscriptionInsightAgentOrder, available: Set(byAgent.keys))
        VStack(alignment: .leading, spacing: 16) {
            heading
            if agents.isEmpty {
                HStack(spacing: 8) {
                    if model.isSubscriptionUsageEstimating { ProgressView().controlSize(.small) }
                    else { Image(systemName: "chart.bar.xaxis") }
                    Text(model.isSubscriptionUsageEstimating ? "正在计算用量预估…" : "暂无可用于估算的额度记录")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(Array(agents.enumerated()), id: \.element) { index, agent in
                let byAccount = Dictionary(grouping: byAgent[agent] ?? [], by: \.feeKey)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(byAccount.keys.sorted(), id: \.self) { key in
                        if let windows = byAccount[key], let first = windows.first {
                            let ordered = windows.sorted {
                                if $0.isActive != $1.isActive { return $0.isActive }
                                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
                            }
                            SubscriptionAccountInsights(model: model, windows: ordered, account: first,
                                                        showOfficial: showOfficial,
                                                        reorder: cardDrag(for: agent, at: index, agents: agents))
                        }
                    }
                }
                .opacity(drag?.agent == agent ? 0.65 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[agent] = $0 }
                .overlay(alignment: dropLine(at: index, agents: agents)) {
                    if let drag, drag.agent != agent, target(at: drag.point, agents: agents) == agent {
                        Capsule().fill(Color.accentColor).frame(height: 3)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
        .task(id: drag?.agent) {
            while let drag, !Task.isCancelled {
                scrollNearEdge(drag.point)
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("用量洞察").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let at = model.subscriptionUsageAsOf {
                Text("截至 \(insightDate(at, in: model.displayTimeZone, full: true)) · \(model.displayTimeZone.identifier)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    private func cardDrag(for agent: Provider, at index: Int, agents: [Provider]) -> SubscriptionAgentCardDrag {
        SubscriptionAgentCardDrag(
            index: index, count: agents.count,
            changed: { drag = Drag(agent: agent, point: $0) },
            ended: { point in
                drag = nil
                if let target = target(at: point, agents: agents), target != agent { move(agent, to: target) }
            },
            cancelled: { if drag?.agent == agent { drag = nil } },
            nudge: { offset in
                let position = index + offset
                guard agents.indices.contains(position) else { return .ignored }
                move(agent, to: agents[position])
                return .handled
            }
        )
    }

    private func move(_ agent: Provider, to target: Provider) {
        withAnimation(.easeInOut(duration: 0.18)) { model.moveSubscriptionInsightAgent(agent, to: target) }
    }

    private func target(at point: CGPoint, agents: [Provider]) -> Provider? {
        agents.first { frames[$0]?.insetBy(dx: 0, dy: -8).contains(point) == true }
    }

    private func dropLine(at index: Int, agents: [Provider]) -> Alignment {
        guard let drag, let source = agents.firstIndex(of: drag.agent) else { return .top }
        return source < index ? .bottom : .top
    }
}

private struct SubscriptionAccountInsights: View {
    let model: AppModel
    let windows: [UsageQuotaInsights.Window]
    let account: UsageQuotaInsights.Window
    let showOfficial: (String) -> Void
    let reorder: SubscriptionAgentCardDrag

    private var agent: Agent {
        switch account.provider {
        case .codex: .codex
        case .claude: .claudeCode
        case .gemini: .antigravity
        }
    }

    private var official: QuotaAccount? {
        model.quotaAccounts.first {
            ($0.agent == agent || (agent == .claudeCode && $0.agent == .claudeDesktop))
                && $0.accountEmail?.caseInsensitiveCompare(account.account) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    AgentMark(agent: agent, size: 25)
                        .frame(width: 40, height: 40)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.provider.insightAgentName).font(.headline)
                        Text(insightMaskedAccount(account.account))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                }
                .modifier(reorder)
                if let official {
                    Button("官方读数", systemImage: "arrow.up") { showOfficial(official.id) }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            ForEach(windows) { window in
                Divider()
                SubscriptionWindowInsights(window: window, zone: model.displayTimeZone)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SubscriptionWindowInsights: View {
    let window: UsageQuotaInsights.Window
    let zone: TimeZone
    @State private var expanded = false
    @State private var showExpired = false
    @Environment(\.colorScheme) private var scheme
    private var partial: Bool { window.currentCycle.coverageIncomplete }

    var body: some View {
        if window.isActive {
            VStack(alignment: .leading, spacing: 10) { title; content }
        } else {
            DisclosureGroup(isExpanded: $showExpired) { content.padding(.top, 8) } label: { title }
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(window.label).font(.subheadline.weight(.semibold))
            InsightChip(title: window.isActive ? "进行中" : window.quality.contains(.expiredWindow) ? "已结束" : "非当前")
            Spacer(minLength: 4)
            Text("已用 \(insightPercent(window.usedPercent)) · \(insightDate(window.observedAt, in: zone))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("窗口 \(insightDate(window.start, in: zone)) → \(insightDate(window.resetsAt, in: zone))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    metrics.frame(minWidth: 302)
                    recent.frame(minWidth: 220, idealWidth: 282, maxWidth: 310)
                }
                VStack(alignment: .leading, spacing: 12) { metrics; recent }
            }
            if !window.quality.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { qualityChips }
                    VStack(alignment: .leading, spacing: 4) { qualityChips }
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    SubscriptionCycleHistory(window: window, zone: zone)
                        .padding(.top, 12)
                }
            } label: {
                Text("历史与周期")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow(alignment: .top) {
                    InsightMetric("已观测 API 价值", value: window.observedCostUSD)
                    InsightMetric(partial ? "整窗参考价值" : "估算整窗价值", value: window.estimatedFullUSD,
                                  uncertainty: window.fullUncertaintyUSD, isEstimate: true, partial: partial)
                }
                GridRow(alignment: .top) {
                    InsightMetric(partial ? "剩余参考价值" : "估算剩余价值", value: window.estimatedRemainingUSD,
                                  uncertainty: window.remainingUncertaintyUSD, isEstimate: true, partial: partial)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("窗口请求").font(.caption).foregroundStyle(.secondary)
                        Text(window.requests.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                        if let coverage {
                            Text(coverage).font(.caption2).foregroundStyle(insightWarning(scheme))
                        }
                    }
                }
            }
            if partial && window.unattributedRequests > 0 {
                Text("同渠道 \(window.unattributedRequests.formatted()) 条请求账号未确认，未计入。")
                    .font(.caption2).foregroundStyle(insightWarning(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coverage: String? {
        if partial && window.requests == 0 { return "没有已确认归属的请求" }
        var notes: [String] = []
        if window.unpricedRequests > 0 { notes.append("\(window.unpricedRequests.formatted()) 次未计价") }
        if window.inferredAccountRequests > 0 { notes.append("\(window.inferredAccountRequests.formatted()) 次账号为推断") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private var qualityChips: some View {
        ForEach(window.quality, id: \.rawValue) { item in
            InsightChip(title: insightQuality(item.rawValue), warning: true)
        }
    }

    private var recent: some View {
        let usage = window.recentUsage
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("最近确认 100%").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                InsightChip(title: usage.usedPercent == 100 ? "用量已确认" : insightRecentStatus(usage.status.rawValue),
                            warning: usage.usedPercent < 100)
            }
            Text(insightMoney(usage.costUSD)).font(.title2.weight(.semibold)).monospacedDigit()
            if usage.usedPercent > 0 {
                ProgressView(value: min(100, max(0, usage.usedPercent)), total: 100)
                    .accessibilityLabel("已确认用量")
                Text("已确认 \(insightPercent(usage.usedPercent)) · \(usage.cycleCount) 个周期")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("尚无可确认的完整计价区间").font(.caption).foregroundStyle(.secondary)
            }
            if usage.from != nil || usage.to != nil {
                Text("\(insightDate(usage.from, in: zone)) → \(insightDate(usage.to, in: zone))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if usage.boundaryProrated {
                Label("最早周期按比例折算", systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary)
            }
            if usage.unpricedRequests > 0 {
                Text("\(usage.unpricedRequests) 个请求未计价").font(.caption2).foregroundStyle(insightWarning(scheme))
            }
            if usage.coverageIncomplete {
                Text(usage.unattributedRequests > 0
                     ? "费用仅含已归属 · \(usage.unattributedRequests.formatted()) 条未确认归属"
                     : "费用覆盖不完整 · 仅显示已计价部分")
                    .font(.caption2).foregroundStyle(insightWarning(scheme))
            }
            if usage.status.rawValue != "ready", let observed = usage.observedCostUSD {
                Text("已观测 \(insightMoney(observed))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.40), in: RoundedRectangle(cornerRadius: 9))
        .help("从最近的已确认用量向前跨重置周期累计；最后一次读数之后的用量不计入。")
    }
}

private struct SubscriptionCycleHistory: View {
    let window: UsageQuotaInsights.Window
    let zone: TimeZone
    @State private var selection: String?
    @State private var preparedPlot: CyclePlot?
    @State private var historyExpanded = false
    @State private var showAllCycles = false
    @AppStorage("subscriptionChartRecentCycleCount") private var recentCycleCount = 0
    @State private var showsRangeEditor = false
    @State private var cycleCountDraft = ""
    @State private var interaction = CycleInteraction()
    @State private var keyboardDetails = false
    @FocusState private var chartFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var cycles: [UsageQuotaInsights.Cycle] {
        guard recentCycleCount > 0 else { return window.cycles }
        let dated = window.cycles.filter { $0.start != nil }
        // If there is no drawable start, still let the user inspect the recorded cycles.
        return dated.isEmpty ? window.cycles : Array(dated.suffix(recentCycleCount))
    }

    private var rangeTitle: String {
        recentCycleCount > 0 ? "最近 \(recentCycleCount.formatted()) 个周期" : "全部周期"
    }

    private var customCycleCount: Int? {
        Int(cycleCountDraft.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
    }
    private var selectedIndex: Int {
        cycles.firstIndex { $0.id == selection } ?? cycles.firstIndex(where: \.isCurrent) ?? max(0, cycles.count - 1)
    }
    private var selected: UsageQuotaInsights.Cycle? {
        cycles.indices.contains(selectedIndex) ? cycles[selectedIndex] : nil
    }

    var body: some View {
        let input = CyclePlotInput(history: window.history, cycles: cycles, recentCycleCount: recentCycleCount)
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        chartTitle.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        cycleRangePicker
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        chartTitle
                        cycleRangePicker
                    }
                }
                if let plot = preparedPlot, plot.recentCycleCount == input.recentCycleCount {
                    if let domain = plot.domain, plot.hasValue {
                        chartKey(plot)
                        combinedChart(plot, domain: domain)
                        if plot.points.isEmpty { empty("此范围暂无官方已用额度读数") }
                        CycleDetailsDock(plot: plot, selected: selected, interaction: interaction, details: details)
                    } else {
                        empty("暂无官方已用读数或可绘制的周期金额")
                    }
                } else {
                    empty("正在整理图表…")
                        .frame(maxWidth: .infinity).frame(height: 206)
                }
            }
            if cycles.isEmpty {
                empty("尚无已观测周期")
            } else {
                cyclePicker
                DisclosureGroup("历史周期（\(cycles.count)）", isExpanded: $historyExpanded) {
                    cycleList.padding(.top, 7)
                }
            }
        }
        .task(id: input) {
            let worker = Task.detached(priority: .userInitiated) { CyclePlot(input) }
            let plot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let plot else { return }
            preparedPlot = plot
        }
        .onChange(of: recentCycleCount) { _, _ in
            if !cycles.contains(where: { $0.id == selection }) { selection = nil }
            interaction.hoveredCycleID = nil
            keyboardDetails = false
            showAllCycles = false
        }
    }

    private var chartTitle: some View {
        Text("官方已用额度与周期 API 等价价值")
            .font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private var cycleRangePicker: some View {
        Button {
            cycleCountDraft = recentCycleCount > 0 ? String(recentCycleCount) : ""
            showsRangeEditor = true
        } label: {
            HStack(spacing: 4) {
                Text(rangeTitle)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).accessibilityHidden(true)
            }
            .fixedSize()
        }
        .controlSize(.small)
        .disabled(!window.cycles.contains { $0.start != nil })
        .accessibilityLabel("横轴范围")
        .accessibilityValue(rangeTitle)
        .popover(isPresented: $showsRangeEditor, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("横轴范围").font(.headline)
                HStack(spacing: 6) {
                    Text("最近")
                    TextField("周期数", text: $cycleCountDraft)
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 74)
                        .accessibilityLabel("最近周期数")
                        .onSubmit {
                            if let count = customCycleCount { setCycleRange(count) }
                        }
                    Text("个周期")
                }
                HStack {
                    Button("全部周期") { setCycleRange(0) }
                    Spacer(minLength: 10)
                    Button("应用") {
                        if let count = customCycleCount { setCycleRange(count) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customCycleCount == nil)
                }
            }
            .padding(14)
        }
    }

    private func setCycleRange(_ count: Int) {
        recentCycleCount = count
        showsRangeEditor = false
    }

    private struct CyclePlotInput: Equatable, Sendable {
        let history: [UsageQuotaInsights.HistoryPoint]
        let cycles: [UsageQuotaInsights.Cycle]
        let recentCycleCount: Int
    }

    private struct ObservedPoint: Identifiable, Sendable {
        let index: Int
        let segment: Int
        let at: Date
        let used: Double
        let correction: Bool
        var drawsLine = true
        var drawsSymbol = true
        var id: Int { index }
    }

    private struct CyclePlot: Sendable {
        let cycles: [UsageQuotaInsights.Cycle]
        let starts: [Date]
        let cycleIndices: [String: Int]
        let pricedCycles: [UsageQuotaInsights.Cycle]
        let estimateSegments: [String: Int]
        let points: [ObservedPoint]
        let recentCycleCount: Int
        let domain: ClosedRange<Date>?
        let axisDates: [Date]
        let maximum: Double
        let hasCost: Bool
        var hasValue: Bool { hasCost || !points.isEmpty }

        private static let targetPoints = 416
        private static let maximumPoints = 768
        private static let maximumPriceCycles = 160

        init?(_ input: CyclePlotInput) {
            // Core publishes both arrays in chronological order.
            let cycles = input.cycles.filter { $0.start != nil }
            let starts = cycles.compactMap(\.start)
            self.cycles = cycles
            self.starts = starts
            recentCycleCount = input.recentCycleCount
            cycleIndices = Dictionary(cycles.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, latest in latest })
            var points: [ObservedPoint] = []
            var segment = 0, cycle = -1
            let history = input.history
            // A period limit crops the official reading series as well as the cost marks.
            let readingRange: ClosedRange<Date>? = if input.recentCycleCount > 0,
                                                      let first = starts.first, let last = cycles.last {
                first...max(last.observedAt, last.start ?? first)
            } else {
                nil
            }
            for (index, point) in history.enumerated() {
                if index.isMultiple(of: 512), Task.isCancelled { return nil }
                guard (0...100).contains(point.usedPercent),
                      readingRange?.contains(point.at) ?? true else { continue }
                let previousCycle = cycle
                while cycle + 1 < starts.count, starts[cycle + 1] <= point.at { cycle += 1 }
                let correction = cycle == previousCycle && (points.last?.used ?? 0) > point.usedPercent
                if cycle != previousCycle || correction { segment += 1 }
                points.append(.init(index: index, segment: segment, at: point.at, used: point.usedPercent, correction: correction))
            }
            self.points = Self.displayPoints(points)
            let priced = cycles.filter { $0.observedCostUSD != nil || $0.estimatedFullUSD != nil }
            pricedCycles = Self.displayCycles(priced)
            // Split on missing estimates before downsampling; a cycle with a bar but
            // no estimate must not bridge the blue line across that gap.
            var estimateSegment = 0
            var estimateSegments: [String: Int] = [:]
            for cycle in cycles {
                if let estimate = cycle.estimatedFullUSD, estimate.isFinite {
                    estimateSegments[cycle.id] = estimateSegment
                } else {
                    estimateSegment += 1
                }
            }
            self.estimateSegments = estimateSegments
            hasCost = !priced.isEmpty
            let peak = priced.map(Self.maximumCost).max() ?? 0
            if peak > 0 {
                let unit = pow(10, floor(log10(peak)))
                maximum = ([1.0, 2, 4, 5, 10].first { $0 * unit >= peak } ?? 10) * unit
            } else {
                maximum = 1
            }
            let endpoints = [starts.first, starts.last, points.first?.at, points.last?.at].compactMap { $0 }
            if let first = endpoints.min(), let last = endpoints.max() {
                let span = last.timeIntervalSince(first)
                let padding = span > 0 ? max(60, span * 0.027) : 1_800
                domain = first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
                axisDates = span >= 180
                    ? (0...3).map { first.addingTimeInterval(span * Double($0) / 3) } : [first]
            } else {
                domain = nil
                axisDates = []
            }
        }

        func scale(_ usd: Double) -> Double { min(100, max(0, usd / maximum * 100)) }

        func firstStart(after date: Date) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= date { low = mid + 1 } else { high = mid }
            }
            return low
        }

        private static func maximumCost(_ cycle: UsageQuotaInsights.Cycle) -> Double {
            let estimate = cycle.estimatedFullUSD ?? 0
            let upper = cycle.fullUncertaintyUSD.flatMap { $0.isFinite ? estimate + $0 : nil } ?? estimate
            return max(0, cycle.observedCostUSD ?? 0, upper)
        }

        private static func displayCycles(_ cycles: [UsageQuotaInsights.Cycle]) -> [UsageQuotaInsights.Cycle] {
            guard cycles.count > maximumPriceCycles else { return cycles }
            let bucketCount = (maximumPriceCycles - 3) / 3
            var picked: Set<Int> = [0, cycles.count - 1]
            if let current = cycles.firstIndex(where: \.isCurrent) { picked.insert(current) }
            for bin in 0..<bucketCount {
                let slice = (cycles.count * bin / bucketCount)..<(cycles.count * (bin + 1) / bucketCount)
                picked.insert(slice.lowerBound)
                if let observed = slice.max(by: { (cycles[$0].observedCostUSD ?? -1) < (cycles[$1].observedCostUSD ?? -1) }) {
                    picked.insert(observed)
                }
                if let peak = slice.max(by: { maximumCost(cycles[$0]) < maximumCost(cycles[$1]) }) {
                    picked.insert(peak)
                }
            }
            return picked.sorted().map { cycles[$0] }
        }

        /// Reduce only plotted vertices. A retained point always keeps its original segment,
        /// so even an extremely dense run cannot join across a reset or correction.
        private static func displayPoints(_ points: [ObservedPoint]) -> [ObservedPoint] {
            guard points.count > targetPoints else { return points }
            var anchors: Set<Int> = []
            var first = 0
            while first < points.count {
                var last = first, minimum = first, maximum = first
                while last + 1 < points.count, points[last + 1].segment == points[first].segment {
                    last += 1
                    if points[last].used < points[minimum].used { minimum = last }
                    if points[last].used > points[maximum].used { maximum = last }
                }
                anchors.formUnion([first, last, minimum, maximum])
                first = last + 1
            }
            var selected: [Int]
            if anchors.count > maximumPoints {
                // Pathological density: preserve the time envelope and its segment IDs
                // within a hard drawing budget, while leaving all input observations intact.
                selected = envelope(anchors.sorted(), points: points, limit: maximumPoints)
            } else {
                let room = targetPoints - anchors.count
                if room >= 4 {
                    let interior = points.indices.filter { !anchors.contains($0) }
                    anchors.formUnion(envelope(interior, points: points, limit: room))
                }
                selected = anchors.sorted()
            }
            let symbolStep = max(1, (selected.count + 95) / 96)
            return selected.enumerated().map { offset, index in
                var point = points[index]
                let left = offset > 0 && points[selected[offset - 1]].segment == point.segment
                let right = offset + 1 < selected.count && points[selected[offset + 1]].segment == point.segment
                point.drawsLine = left || right
                point.drawsSymbol = !left || !right || point.correction || offset.isMultiple(of: symbolStep)
                return point
            }
        }

        /// Sample time bins with the first, last, minimum and maximum actual readings.
        private static func envelope(_ indices: [Int], points: [ObservedPoint], limit: Int) -> [Int] {
            guard indices.count > limit, limit >= 4, let first = indices.first, let last = indices.last else { return indices }
            let count = limit / 4
            let origin = points[first].at
            let duration = points[last].at.timeIntervalSince(origin)
            var buckets: [(first: Int, last: Int, low: Int, high: Int)?] = Array(repeating: nil, count: count)
            for (offset, index) in indices.enumerated() {
                let fraction = duration > 0 ? points[index].at.timeIntervalSince(origin) / duration : Double(offset) / Double(indices.count)
                let bucket = min(count - 1, max(0, Int(fraction * Double(count))))
                if var bounds = buckets[bucket] {
                    bounds.last = index
                    if points[index].used < points[bounds.low].used { bounds.low = index }
                    if points[index].used > points[bounds.high].used { bounds.high = index }
                    buckets[bucket] = bounds
                } else {
                    buckets[bucket] = (index, index, index, index)
                }
            }
            return Set(buckets.compactMap { $0 }.flatMap { [$0.first, $0.last, $0.low, $0.high] }).sorted()
        }
    }

    private var readingColor: Color {
        if contrast == .increased {
            return scheme == .dark ? Color(red: 0.38, green: 0.88, blue: 0.92) : Color(red: 0.05, green: 0.39, blue: 0.45)
        }
        return ModelChartPalette.color(slot: 5)
    }

    private var chartInk: Color { .primary.opacity(contrast == .increased ? 1 : 0.77) }
    private var barColor: Color { .primary.opacity(contrast == .increased ? 0.34 : 0.18) }
    private var axisPercents: [Double] { [0, 25, 50, 75, 100] }

    private func chartKey(_ plot: CyclePlot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                axisKey("官方已用额度 (%)", image: "circle.fill", color: readingColor)
                Spacer(minLength: 0)
                costKey(plot)
            }
            VStack(alignment: .leading, spacing: 4) {
                axisKey("官方已用额度 (%)", image: "circle.fill", color: readingColor)
                costKey(plot)
            }
        }
        .font(.caption2)
    }

    private func costKey(_ plot: CyclePlot) -> some View {
        HStack(spacing: 8) {
            if plot.hasCost {
                axisKey("已观测", image: "rectangle.portrait.fill", color: chartInk.opacity(0.6))
                axisKey("整窗估算", image: "circle.fill", color: .accentColor)
                if plot.cycles.contains(where: { $0.estimatedFullUSD != nil && ($0.coverageIncomplete || $0.unpricedRequests > 0) }) {
                    axisKey("覆盖不完整", image: "circle", color: .accentColor)
                }
            }
            Text(plot.hasCost ? "API 等价价值 (USD)" : "API 等价价值未知")
                .foregroundStyle(chartInk)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func axisKey(_ label: String, image: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: image).font(.system(size: 7)).foregroundStyle(color).accessibilityHidden(true)
            Text(label).foregroundStyle(chartInk)
        }
        .fixedSize()
    }

    private func combinedChart(_ plot: CyclePlot, domain: ClosedRange<Date>) -> some View {
        Chart {
            amountMarks(plot)
            if let selected, let index = plot.cycleIndices[selected.id] {
                let date = plot.starts[index]
                RuleMark(x: .value("所选周期", date))
                    .foregroundStyle(Color.secondary.opacity(chartFocused ? 0.65 : 0.4))
                    .lineStyle(.init(lineWidth: 1, dash: [3, 4]))
                    .accessibilityHidden(true)
            }
            readingMarks(plot.points)
        }
        .chartYScale(domain: 0.0...100.0)
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: plot.axisDates) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            }
        }
        .chartYAxis { yAxes(plot) }
        .chartOverlay { proxy in
            CycleOverlay(plot: plot, proxy: proxy, domain: domain, interaction: interaction,
                         keyboardCycleID: chartFocused && keyboardDetails ? selected?.id : nil, labels: { frame, width in
                timeLabels(plot.axisDates, proxy: proxy, frame: frame, width: width,
                           span: domain.upperBound.timeIntervalSince(domain.lowerBound))
            }, details: details) { id in
                selection = id
                keyboardDetails = false
                chartFocused = true
            }
        }
        .environment(\.timeZone, zone)
        .accessibilityLabel("官方已用额度与周期 API 等价价值")
        .accessibilityValue(selected.map(cycleAccessibilityValue) ?? "")
        .accessibilityHint("方向键切换周期，可读取所选周期详情")
        .focusable()
        .focused($chartFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { select(-1); keyboardDetails = true; return .handled }
        .onKeyPress(.rightArrow) { select(1); keyboardDetails = true; return .handled }
        .onKeyPress(.escape) { keyboardDetails = false; return .handled }
        .onChange(of: chartFocused) { _, focused in if !focused { keyboardDetails = false } }
        .padding(.bottom, 18)
        .frame(height: 206)
    }

    /// The overlay and dock observe pointer changes; the chart's marks do not.
    @Observable fileprivate final class CycleInteraction {
        var hoveredCycleID: String?
        var layout: Layout?
        struct Layout: Equatable {
            let width: CGFloat
            let wide: Bool
        }
    }

    private struct CycleDetailsDock<Details: View>: View {
        let plot: CyclePlot
        let selected: UsageQuotaInsights.Cycle?
        let interaction: CycleInteraction
        let details: (UsageQuotaInsights.Cycle, CGFloat, Bool) -> Details

        var body: some View {
            if let layout = interaction.layout, !layout.wide {
                let hovered = interaction.hoveredCycleID.flatMap { plot.cycleIndices[$0] }.map { plot.cycles[$0] }
                if let cycle = hovered ?? selected {
                    details(cycle, layout.width, false)
                        .allowsHitTesting(false)
                        .accessibilityHidden(hovered != nil)
                }
            }
        }
    }

    private struct CycleOverlay<Labels: View, Details: View>: View {
        let plot: CyclePlot
        let proxy: ChartProxy
        let domain: ClosedRange<Date>
        let interaction: CycleInteraction
        let keyboardCycleID: String?
        let labels: (CGRect, CGFloat) -> Labels
        let details: (UsageQuotaInsights.Cycle, CGFloat, Bool) -> Details
        let pick: (String) -> Void
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let id = cycle(at: location, geometry: geometry)?.id
                            if interaction.hoveredCycleID != id { interaction.hoveredCycleID = id }
                        case .ended:
                            interaction.hoveredCycleID = nil
                        }
                    }
                    .onTapGesture { location in
                        if let cycle = cycle(at: location, geometry: geometry, allowsNearest: true) { pick(cycle.id) }
                    }
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    let layout = CycleInteraction.Layout(width: geometry.size.width, wide: frame.width >= 1100)
                    labels(frame, geometry.size.width)
                        .onChange(of: layout, initial: true) { _, updated in interaction.layout = updated }
                    if let id = interaction.hoveredCycleID ?? keyboardCycleID, let index = plot.cycleIndices[id],
                       let x = proxy.position(forX: plot.starts[index]) {
                        let span = cycleSpan(at: index, x: x, frame: frame)
                        cycleHighlight(span, frame: frame)
                        if layout.wide {
                            let width: CGFloat = 720
                            let left = frame.minX + span.lowerBound
                            let right = frame.minX + span.upperBound
                            let preferred = frame.maxX - right >= left - frame.minX ? right + 8 : left - width - 8
                            let x = max(frame.minX + 8, min(preferred, frame.maxX - width - 8))
                            details(plot.cycles[index], width, true)
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(x: x, y: frame.minY + 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }

        private func cycleSpan(at index: Int, x: CGFloat, frame: CGRect) -> ClosedRange<CGFloat> {
            let cycle = plot.cycles[index]
            let end = cycle.resetsAt ?? cycle.observedAt
            let next = plot.starts.indices.contains(index + 1) ? plot.starts[index + 1] : domain.upperBound
            let trailing = min(domain.upperBound, max(plot.starts[index], min(next, end)))
            let endX = proxy.position(forX: trailing) ?? x
            let left = min(frame.width, max(0, x))
            let width = min(frame.width - left, max(1, endX - left))
            return left...(left + width)
        }

        private func cycleHighlight(_ span: ClosedRange<CGFloat>, frame: CGRect) -> some View {
            Rectangle()
                .fill(Color.accentColor.opacity(contrast == .increased ? 0.25 : 0.15))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor.opacity(contrast == .increased ? 0.75 : 0.5)).frame(width: 1)
                }
                .frame(width: span.upperBound - span.lowerBound, height: frame.height)
                .offset(x: frame.minX + span.lowerBound, y: frame.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }

        /// Consider the nearest start on either side of the pointer, then its actual
        /// cycle. An unobserved gap does not get a hover card from a distant cycle.
        private func cycle(at location: CGPoint, geometry: GeometryProxy,
                           allowsNearest: Bool = false) -> UsageQuotaInsights.Cycle? {
            guard let anchor = proxy.plotFrame else { return nil }
            let frame = geometry[anchor]
            guard frame.contains(location) else { return nil }
            let x = location.x - frame.minX
            guard let time = proxy.value(atX: x, as: Date.self) else { return nil }
            let next = plot.firstStart(after: time)
            var nearest: (index: Int, distance: CGFloat)?
            for index in [next - 1, next] where plot.cycles.indices.contains(index) {
                guard let position = proxy.position(forX: plot.starts[index]) else { continue }
                let distance = abs(position - x)
                if nearest.map({ distance < $0.distance }) ?? true { nearest = (index, distance) }
            }
            if let nearest, nearest.distance <= 10 { return plot.cycles[nearest.index] }
            if next > 0 {
                let previous = plot.cycles[next - 1]
                if previous.resetsAt.map({ time < $0 }) ?? (time <= previous.observedAt) { return previous }
            }
            return allowsNearest ? nearest.map { plot.cycles[$0.index] } : nil
        }
    }

    @ChartContentBuilder private func amountMarks(_ plot: CyclePlot) -> some ChartContent {
        ForEach(plot.pricedCycles) { cycle in
            if let date = cycle.start {
                if let observed = cycle.observedCostUSD {
                    BarMark(x: .value("周期开始", date), y: .value("已观测", plot.scale(observed)), width: .fixed(13))
                        .cornerRadius(2).foregroundStyle(barColor)
                        .accessibilityLabel(insightDate(date, in: zone))
                        .accessibilityValue("已观测 API 价值 " + insightMoney(observed))
                }
                if let estimate = cycle.estimatedFullUSD, let segment = plot.estimateSegments[cycle.id] {
                    LineMark(x: .value("周期开始", date), y: .value("整窗估算", plot.scale(estimate)),
                             series: .value("连续估算", "estimate-\(segment)"))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(.init(lineWidth: 1.5, lineCap: .round))
                        .interpolationMethod(.linear).accessibilityHidden(true)
                    if let error = cycle.fullUncertaintyUSD, error.isFinite {
                        RuleMark(x: .value("周期开始", date),
                                 yStart: .value("估算下界", plot.scale(max(0, estimate - error))),
                                 yEnd: .value("估算上界", plot.scale(estimate + error)))
                            .foregroundStyle(Color.secondary.opacity(0.7)).accessibilityHidden(true)
                    }
                    PointMark(x: .value("周期开始", date), y: .value("整窗估算", plot.scale(estimate)))
                        .foregroundStyle(Color.accentColor)
                        .symbol {
                            if cycle.coverageIncomplete || cycle.unpricedRequests > 0 {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 1.4).frame(width: 8, height: 8)
                            } else {
                                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            }
                        }
                        .accessibilityLabel(insightDate(date, in: zone))
                        .accessibilityValue("整窗估算 " + insightEstimate(estimate, cycle.fullUncertaintyUSD, partial: cycle.coverageIncomplete))
                }
            }
        }
    }

    @ChartContentBuilder private func readingMarks(_ points: [ObservedPoint]) -> some ChartContent {
        ForEach(points) { point in
            if point.drawsLine {
                LineMark(x: .value("官方观测时间", point.at), y: .value("已用额度", point.used),
                         series: .value("连续官方读数", "reading-\(point.segment)"))
                    .foregroundStyle(readingColor).lineStyle(.init(lineWidth: 1.75, lineCap: .round))
                    .interpolationMethod(.linear).accessibilityHidden(true)
            }
            if point.drawsSymbol {
                PointMark(x: .value("官方观测时间", point.at), y: .value("已用额度", point.used))
                    .foregroundStyle(readingColor)
                    .symbol {
                        if point.correction {
                            Circle().strokeBorder(readingColor, lineWidth: 1.1).frame(width: 6, height: 6)
                        } else {
                            Circle().fill(readingColor).frame(width: 4, height: 4)
                        }
                    }
                    .accessibilityLabel(insightDate(point.at, in: zone))
                    .accessibilityValue("官方已用 " + insightPercent(point.used))
            }
        }
    }

    @AxisContentBuilder private func yAxes(_ plot: CyclePlot) -> some AxisContent {
        AxisMarks(position: .leading, values: axisPercents) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            AxisValueLabel {
                if let percent = value.as(Double.self) {
                    Text(insightPercent(percent)).monospacedDigit().foregroundStyle(chartInk)
                }
            }
        }
        if plot.hasCost {
            AxisMarks(position: .trailing, values: axisPercents) { value in
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(percent == 0 ? "$0" : apiCostLabel(plot.maximum * percent / 100, compact: true))
                            .monospacedDigit().foregroundStyle(chartInk)
                    }
                }
            }
        }
    }

    private func timeLabels(_ dates: [Date], proxy: ChartProxy, frame: CGRect, width: CGFloat, span: TimeInterval) -> some View {
        ForEach(dates, id: \.self) { date in
            if let x = proxy.position(forX: date) {
                let label = span < 7 * 86_400 ? insightDate(date, in: zone)
                    : date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_Hans_CN"), timeZone: zone).month().day())
                let half = CGFloat(label.count) * 3.6 + 3
                Text(label).font(.caption2.monospacedDigit()).foregroundStyle(chartInk)
                    .fixedSize()
                    .position(x: min(max(frame.minX + x, half), width - half), y: frame.maxY + 11)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var cyclePicker: some View {
        HStack(spacing: 8) {
            Picker("选中周期", selection: Binding(get: { selected?.id ?? "" }, set: { selection = $0 })) {
                ForEach(cycles) { cycle in Text(cycleLabel(cycle)).tag(cycle.id) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 365)
            ControlGroup {
                Button { select(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(selectedIndex <= 0).accessibilityLabel("前一个周期")
                Button { select(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(selectedIndex >= cycles.count - 1).accessibilityLabel("后一个周期")
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func select(_ delta: Int) {
        let next = selectedIndex + delta
        if cycles.indices.contains(next) { selection = cycles[next].id }
    }

    private func details(_ cycle: UsageQuotaInsights.Cycle, width: CGFloat, floating: Bool) -> some View {
        let stacked = width < 560
        let gap: CGFloat = 16
        let columnRoom = max(0, width - 24 - gap * 2)
        let widths: [CGFloat] = floating ? [190, 254, 220] : [1.0, 1.3, 1.15].map { columnRoom * $0 / 3.45 }
        let info = cycleFacts(cycle)
        let contribution = VStack(alignment: .leading, spacing: 5) {
            Text("设备贡献（\(cycle.devices.count)）").font(.caption.weight(.semibold))
            if cycle.devices.isEmpty { empty("无设备归属数据") }
            else { devices(orderedDevices(cycle.devices)) }
        }
        let breakdown = CycleModelCostShare(cycle.modelCosts, stacked: stacked)
        return VStack(alignment: .leading, spacing: 6) {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    info.frame(minHeight: 108, alignment: .topLeading)
                    contribution.frame(minHeight: 140, alignment: .topLeading)
                    breakdown.frame(minHeight: 108, alignment: .topLeading)
                }
            } else {
                HStack(alignment: .top, spacing: gap) {
                    info.frame(width: widths[0], alignment: .leading)
                    contribution.frame(width: widths[1], alignment: .leading)
                    breakdown.frame(width: widths[2], alignment: .leading)
                }
                .frame(minHeight: floating ? nil : 140, alignment: .topLeading)
            }
            if let note = cycleNote(cycle) {
                Text(note).font(.caption2).foregroundStyle(insightWarning(scheme)).lineLimit(1)
            } else if !floating {
                Color.clear.frame(height: 12).accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(floating ? 0.16 : 0), radius: 4, y: 2)
    }

    private func cycleFacts(_ cycle: UsageQuotaInsights.Cycle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("周期详情").font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                detail("观测开始", insightDate(cycle.start, in: zone))
                detail("计划到期", insightDate(cycle.resetsAt, in: zone))
                detail("最后观测", "\(insightDate(cycle.observedAt, in: zone)) · 已用 \(insightPercent(cycle.usedPercent))")
                detail("已观测", insightMoney(cycle.observedCostUSD))
                detail(cycle.coverageIncomplete ? "整窗参考" : "整窗估算",
                       insightEstimate(cycle.estimatedFullUSD, cycle.fullUncertaintyUSD, partial: cycle.coverageIncomplete))
                if cycle.unpricedRequests > 0 {
                    detail("定价覆盖", "\(cycle.pricedRequests) / \(cycle.eligibleRequests) 已计价", warning: true)
                }
            }
        }
    }

    private func cycleNote(_ cycle: UsageQuotaInsights.Cycle) -> String? {
        if cycle.coverageIncomplete && cycle.unattributedRequests > 0 {
            return "同渠道 \(cycle.unattributedRequests.formatted()) 条请求账号未确认，未计入。"
        }
        return nil
    }

    private func detail(_ key: String, _ value: String, warning: Bool = false) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary).fixedSize()
            Text(value).foregroundStyle(warning ? insightWarning(scheme) : Color.primary).monospacedDigit().lineLimit(1)
        }.font(.caption2)
    }

    private func orderedDevices(_ entries: [UsageQuotaInsights.DeviceContribution]) -> [UsageQuotaInsights.DeviceContribution] {
        entries.sorted {
            if $0.knownCostUSD != $1.knownCostUSD { return ($0.knownCostUSD ?? -1) > ($1.knownCostUSD ?? -1) }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func devices(_ entries: [UsageQuotaInsights.DeviceContribution]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text("设备").gridColumnAlignment(.leading)
                    Text("请求")
                    Text("API 价值")
                    Text("占比")
                }
                .foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
                Divider()
                ForEach(entries.prefix(5)) { device in
                    GridRow {
                        Text(device.name).lineLimit(1).truncationMode(.middle).gridColumnAlignment(.leading)
                        Text(device.requests.formatted()).fixedSize()
                        Text(insightMoney(device.knownCostUSD))
                            .fixedSize().foregroundStyle(device.unpricedRequests > 0 ? insightWarning(scheme) : Color.primary)
                        Text(device.priceShare.map { insightPercent(100 * $0) } ?? "—").fixedSize()
                    }
                }
            }
            .font(.caption2).monospacedDigit()
            if entries.count > 5 {
                Text("另有 \(entries.count - 5) 台设备").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func cycleAccessibilityValue(_ cycle: UsageQuotaInsights.Cycle) -> String {
        let amounts = "已用 \(insightPercent(cycle.usedPercent))，已观测 \(insightMoney(cycle.observedCostUSD))，整窗 \(insightEstimate(cycle.estimatedFullUSD, cycle.fullUncertaintyUSD, partial: cycle.coverageIncomplete))"
        let devices = orderedDevices(cycle.devices).map { "\($0.name)：\($0.requests) 次请求，\(insightMoney($0.knownCostUSD))" }
        let modelCosts = CycleModelCostShare(cycle.modelCosts, stacked: false).accessibilitySummary
        return ([cycleLabel(cycle), amounts, "设备贡献 \(cycle.devices.count) 台"] + devices + [modelCosts]).joined(separator: "，")
    }

    private var cycleList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Grid(alignment: .trailing, horizontalSpacing: 9, verticalSpacing: 5) {
                GridRow {
                    Text("周期").gridColumnAlignment(.leading)
                    Text("已用")
                    Text("已观测")
                    Text("整窗估算")
                    Text("请求")
                }
                .foregroundStyle(.secondary)
                Divider()
                ForEach(cycles.reversed().prefix(showAllCycles ? cycles.count : 8)) { cycle in
                    GridRow {
                        Button {
                            selection = cycle.id
                        } label: {
                            Text(insightDate(cycle.start, in: zone) + (cycle.isCurrent ? "（当前）" : ""))
                                .lineLimit(1)
                        }
                        .buttonStyle(.link).gridColumnAlignment(.leading)
                        Text(insightPercent(cycle.usedPercent)).fixedSize()
                        Text(insightMoney(cycle.observedCostUSD)).fixedSize()
                        Text(insightEstimate(cycle.estimatedFullUSD, cycle.fullUncertaintyUSD, partial: cycle.coverageIncomplete)).lineLimit(1)
                        Text(cycle.requests.formatted()).fixedSize()
                    }
                }
            }
            .font(.caption).monospacedDigit()
            if cycles.count > 8 {
                Button(showAllCycles ? "收起较早周期" : "显示更早 \(cycles.count - 8) 个周期") { showAllCycles.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func cycleLabel(_ cycle: UsageQuotaInsights.Cycle) -> String {
        "\(insightDate(cycle.start, in: zone)) · 计划 \(insightDate(cycle.resetsAt, in: zone))"
            + (cycle.isCurrent ? "（当前）" : "")
    }

    private func empty(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }
}

private struct InsightChip: View {
    let title: String
    var warning = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(warning ? insightWarning(scheme) : Color.secondary)
            .background(.quaternary, in: Capsule())
    }
}

private struct InsightMetric: View {
    let title: String
    let value: Double?
    let uncertainty: Double?
    let isEstimate: Bool
    let partial: Bool

    init(_ title: String, value: Double?, uncertainty: Double? = nil, isEstimate: Bool = false, partial: Bool = false) {
        self.title = title; self.value = value; self.uncertainty = uncertainty; self.isEstimate = isEstimate
        self.partial = partial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text((isEstimate && value != nil ? "≈ " : "") + insightMoney(value))
                .font(.title3.weight(.semibold)).monospacedDigit()
            if isEstimate, value != nil {
                Text(partial ? "仅已归属" : insightError(uncertainty)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(partial ? "仅用此官方账号已归属且已计价的请求。API Key 和未确认归属的请求不计入。"
              : isEstimate ? "误差仅反映官方额度读数的 ±1 个百分点，不包含未计价或无法归属的请求。"
              : "按当前所选价目计算的 API 等价价值。")
    }
}

private func insightDate(_ date: Date?, in zone: TimeZone, full: Bool = false) -> String {
    guard let date else { return "—" }
    var style = Date.FormatStyle(locale: Locale(identifier: "zh_Hans_CN"), timeZone: zone)
    style = style.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    if full { style = style.year() }
    return date.formatted(style)
}

private func insightMoney(_ value: Double?) -> String {
    value?.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))
        .precision(.fractionLength(2))) ?? "—"
}

private func insightError(_ error: Double?) -> String {
    guard let error else { return "误差未知" }
    return error.isFinite ? "±\(insightMoney(error))" : "误差无上界"
}

private func insightEstimate(_ amount: Double?, _ error: Double?, partial: Bool = false) -> String {
    guard let amount else { return "—" }
    return "≈ \(insightMoney(amount)) " + (partial ? "· 仅已归属" : insightError(error))
}

private func insightWarning(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? .orange : Color(red: 0.56, green: 0.24, blue: 0.06)
}

private func insightPercent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1))) + "%"
}

private func insightMaskedAccount(_ account: String) -> String {
    let parts = account.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else { return String(account.prefix(2)) + "***" }
    let local = parts[0]
    let keep = local.count > 5 ? 2 : local.count > 2 ? 1 : 0
    return String(local.prefix(keep)) + "***" + String(local.suffix(keep)) + "@" + parts[1]
}

private func insightQuality(_ raw: String) -> String {
    switch raw {
    case "missing_window": "缺少窗口边界"
    case "zero_consumption": "读数为零"
    case "stale_quota": "读数已过时"
    case "expired_window": "窗口已结束"
    case "unpriced": "部分请求未计价"
    case "inferred_account": "含推断账号"
    case "partial_history": "费用覆盖不完整"
    default: "数据不完整"
    }
}

private func insightRecentStatus(_ raw: String) -> String {
    switch raw {
    case "ready": "已确认"
    case "partial_history": "历史不完整"
    case "unpriced": "缺少价目"
    case "insufficient_history": "读数不足"
    default: "不可用"
    }
}
