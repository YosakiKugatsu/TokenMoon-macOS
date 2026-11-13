// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Charts
import TokenMoonCore

fileprivate enum Pane: Hashable { case overview, sessions, quotas }

@MainActor @Observable
final class DashboardNavigation {
    var columnVisibility: NavigationSplitViewVisibility = .all
    fileprivate var pane: Pane? = .overview
    fileprivate var metric: Metric = .tokens
    fileprivate var quotaOptionID = ""
    fileprivate var showsQuotaChart = false
    fileprivate var unpricedOnly = false

    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }
}

fileprivate enum Metric: String, CaseIterable, Identifiable {
    case tokens, requests, cost, cache, estimatedTPS
    var id: Self { self }
    var title: String {
        switch self { case .tokens: "Token 用量"; case .requests: "请求次数"; case .cost: "等效费用"; case .cache: "缓存命中"; case .estimatedTPS: "估算 TPS" }
    }
    var symbol: String {
        switch self { case .tokens: "circle.hexagongrid"; case .requests: "arrow.up.arrow.down"; case .cost: "dollarsign.circle"; case .cache: "memorychip"; case .estimatedTPS: "gauge.with.dots.needle.33percent" }
    }
    /// ⌘1–⌘5 follow the tile order; the tiles are the only metric picker.
    var shortcut: KeyEquivalent {
        switch self { case .tokens: "1"; case .requests: "2"; case .cost: "3"; case .cache: "4"; case .estimatedTPS: "5" }
    }
    var usesColumns: Bool {
        switch self { case .tokens, .requests, .cost: true; case .cache, .estimatedTPS: false }
    }
    func value(_ m: UsageMetrics, tpsScope: EstimatedTPSOutputScope) -> Double? {
        switch self {
        case .tokens: Double(m.tokens)
        case .requests: Double(m.requests)
        case .cost: m.cost
        case .cache: m.cacheRate
        case .estimatedTPS: m.estimatedTPS(for: tpsScope)
        }
    }
    func label(_ v: Double?, compact: Bool = false, metrics: UsageMetrics? = nil,
               tpsScope: EstimatedTPSOutputScope = .all) -> String {
        switch self {
        case .estimatedTPS: estimatedTPSLabel(v, missing: "未知", lowerBound: (metrics?.estimatedTPSFallbackSamples(for: tpsScope) ?? 0) == 0)
        case .cost: apiCostLabel(v, compact: compact, missing: "未知")
        default: text(v)
        }
    }
    /// Values match the menu bar and popup: tokens with three significant digits, requests in full.
    func text(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "未知" }
        return switch self {
        case .tokens: compactTokenCount(Int64(exactly: v.rounded()) ?? (v < 0 ? .min : .max))
        case .requests: (Int64(exactly: v.rounded()) ?? (v < 0 ? .min : .max))
            .formatted(.number.locale(Locale(identifier: "en_US")))
        case .cost: apiCostLabel(v)
        case .cache: v.formatted(.percent.precision(.fractionLength(1)))
        case .estimatedTPS: v.formatted(.number.precision(.fractionLength(1)))
        }
    }
    /// Y-axis ticks stay short so a narrow plot never crowds.
    func axisText(_ v: Double) -> String {
        switch self {
        case .tokens, .requests: compactAxisCount(v)
        case .cost: apiCostLabel(v)
        case .cache: v.formatted(.percent.precision(.fractionLength(0...1)))
        case .estimatedTPS: v.formatted(.number.precision(.fractionLength(0...1)))
        }
    }
}

/// A chart bucket applied to the request list. The bounds are the column's own bucket.
private struct RequestWindow: Equatable {
    let title: String
    let start: Date
    let end: Date
}

struct DashboardView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: DashboardNavigation = .init()
    /// The pinned bucket (click or arrow keys). Hover only moves `hoveredDate`.
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @State private var requestWindow: RequestWindow?
    @State private var unpricedDrillDownRevision = 0
    @AppStorage("dashboardEstimatedTPSOutputScope") private var tpsScope: EstimatedTPSOutputScope = .all
    @State private var editingCustomHours = false
    @FocusState private var chartFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var accent: Color { .accentColor }
    private var secondaryInk: Color { .primary.opacity(contrast == .increased ? 1 : 0.77) }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }
    private var metric: Metric { get { navigation.metric } nonmutating set { navigation.metric = newValue } }
    private var quotaOptionID: String { get { navigation.quotaOptionID } nonmutating set { navigation.quotaOptionID = newValue } }
    private var showsQuotaChart: Bool { get { navigation.showsQuotaChart } nonmutating set { navigation.showsQuotaChart = newValue } }
    private var unpricedOnly: Bool { get { navigation.unpricedOnly } nonmutating set { navigation.unpricedOnly = newValue } }

    var body: some View {
        NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            List(selection: $navigation.pane) {
                Section("TokenMoon") {
                    Label("观测台", systemImage: "moon.stars").tag(Pane.overview)
                    Label("会话", systemImage: "text.bubble").tag(Pane.sessions)
                    Label("订阅额度", systemImage: "gauge.with.dots.needle.33percent").tag(Pane.quotas)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch navigation.pane {
            case .sessions: sessions
            case .quotas: QuotaDashboardView(model: model).navigationTitle("订阅额度")
            default: overview
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh() } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small).accessibilityLabel("正在采集")
                    } else {
                        Label("刷新用量", systemImage: model.collectionIssue ? "exclamationmark.arrow.circlepath" : "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .help(model.collectionStatusMessage.isEmpty ? "采集本机用量 (⌘R)" : model.collectionStatusMessage)
            }
        }
    }

    private var overview: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    controls
                    tiles(scroller)
                    if showsQuotaChart {
                        WeeklyQuotaTrendCard(model: model, selection: $navigation.quotaOptionID, option: quotaOption)
                    } else {
                        chartCard(scroller)
                    }
                    dashboardRequestHistory.id("requests")
                }
                .padding(.horizontal, 24).padding(.vertical, 24)
                .frame(maxWidth: 1180).frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("请求记录", systemImage: "list.bullet.rectangle") { scrollToRequests(scroller) }
                        .help("跳到下方的请求记录")
                }
            }
        }
        .navigationTitle("观测台")
        .navigationSubtitle(overviewSubtitle)
        // A new range has different buckets, so a pinned bucket or request window no longer applies.
        .onChange(of: model.range) { clearChartSelection() }
        .onChange(of: model.customHours) { clearChartSelection() }
        .onChange(of: model.displayTimeZoneID) { clearChartSelection() }
        .onChange(of: model.displayTimeZone.identifier) { clearChartSelection() }
        .onChange(of: model.timelineInterval) {
            clearChartSelection()
            if showsQuotaChart { model.refreshQuotaDepletionChart() }
        }
        // A channel the range no longer observes falls back to automatic, i.e. the first (largest) drop.
        .onChange(of: model.quotaDepletionOptions.map(\.id), initial: true) { _, ids in
            if !quotaOptionID.isEmpty, !ids.contains(quotaOptionID) { quotaOptionID = "" }
        }
        .onChange(of: showsQuotaChart ? quotaOption?.id : nil, initial: true) { _, id in
            model.setQuotaDepletionChartSeries(id)
        }
        .onDisappear { model.setQuotaDepletionChartSeries(nil) }
    }

    private var dashboardRequestHistory: some View {
        let scope = requestScopeLabel
        let clear: (() -> Void)? = scope == nil ? nil : { clearRequestScope() }
        return MoonRequestHistory(model: model, requests: historyRequests, scopeLabel: scope,
                                  scopeIcon: unpricedOnly ? "dollarsign.circle" : "clock",
                                  clearScope: clear, filterResetID: unpricedDrillDownRevision)
    }

    /// Range, filters and data age in the window's subtitle instead of a second in-page title.
    private var overviewSubtitle: String {
        let calendar = model.displayCalendar
        // The default API-key exclusion is not a picked filter, so only explicit choices are counted.
        let picked = model.filters.selectedCount
        var parts = [model.range.label, picked == 0 ? "全部来源" : "已选 \(picked) 项筛选"]
        if model.collectionIssue {
            parts.append("采集失败")
        } else if let last = model.lastCollection {
            parts.append("采集于 " + statusClockLabel(last, calendar: calendar))
        }
        if !model.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if model.syncIssue {
                parts.append("同步失败")
            } else {
                parts.append(model.lastSync.map { "同步于 " + statusClockLabel($0, calendar: calendar) } ?? "尚未同步")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var sessions: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            TokenMoonSessionsView(model: model)
        }
        .navigationTitle("会话")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    rangePicker
                    if model.range == .custom {
                        Button { editingCustomHours = true } label: {
                            Label(DashboardDates.rangeLabel(model.customHours, calendar: model.displayCalendar), systemImage: "clock")
                                .monospacedDigit().lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .help("包含结束小时")
                        .accessibilityLabel("编辑自定义时间")
                        .accessibilityValue(DashboardDates.rangeLabel(model.customHours, calendar: model.displayCalendar))
                    }
                }
                .fixedSize()
                .popover(isPresented: $editingCustomHours, arrowEdge: .bottom) {
                    CustomHoursPopover(hours: model.customHours) { hours in
                        editingCustomHours = false
                        model.useCustomHours(hours)
                    }
                }
                if model.range != .custom { filterStrip }
            }
            if model.range == .custom { filterStrip }
        }
    }

    private var filterStrip: some View {
        ScrollView(.horizontal) { filterControls }
            .scrollIndicators(.hidden)
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            filterMenu("模型", "cpu", $model.filters.models, model.models,
                       name: model.modelDisplayName, optionName: model.modelFilterOptionLabel)
            filterMenu("设备", "laptopcomputer", $model.filters.devices, model.devices, name: { model.deviceNames[$0] ?? $0 })
            DashboardFacetPicker(title: "账号", icon: "person.crop.circle", selection: $model.filters.accounts,
                                 values: model.requestAccounts, name: model.accountFilterOptionLabel,
                                 optionName: model.accountFilterOptionLabel,
                                 extraFilter: .init(label: "排除已识别的 API Key 请求", isOn: $model.filters.excludesAPIKeys))
            filterMenu("智能体", "sparkles", $model.filters.agents, model.agents, name: { $0.label })
            filterMenu("请求档位", "dial.low", $model.filters.tiers, model.requestTiers, name: { $0.label })
            filterMenu("状态", "checkmark.circle", $model.filters.statuses, model.requestStatuses, name: { $0.label })
            if model.filters.selectedCount > 0 {
                Button("清除全部筛选", systemImage: "xmark.circle") { model.filters.clearSelections() }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
                    .help("清除全部筛选，保留时间范围和 API Key 排除设置")
            }
        }
        .fixedSize()
    }

    private var rangePicker: some View {
        Menu {
            ForEach(UsageRange.allCases) { range in
                Button {
                    if range == .custom { editingCustomHours = true } else { model.range = range }
                } label: {
                    if model.range == range {
                        Label(range.label + (range == .custom ? "…" : ""), systemImage: "checkmark")
                    } else {
                        Text(range.label + (range == .custom ? "…" : ""))
                    }
                }
                .accessibilityAddTraits(model.range == range ? .isSelected : [])
            }
        } label: {
            Label(model.range.label, systemImage: "calendar")
        }
        .menuStyle(.button).buttonStyle(.bordered).fixedSize()
        .accessibilityLabel("时间范围").accessibilityValue(model.range.label)
    }

    private func filterMenu<Value: Hashable>(_ title: String, _ icon: String, _ selection: Binding<Set<Value>>, _ values: [Value],
                                            name: @escaping (Value) -> String, optionName: ((Value) -> String)? = nil) -> some View {
        DashboardFacetPicker(title: title, icon: icon, selection: selection, values: values,
                             name: name, optionName: optionName ?? name)
    }

    private func tile(_ m: Metric, scroller: ScrollViewProxy) -> some View {
        let v = m.value(model.metrics, tpsScope: tpsScope)
        let on = !showsQuotaChart && metric == m
        let detail = m == .estimatedTPS && tpsScope == .over800 ? "输出 > 800 Token" : nil
        let unpriced = m == .cost ? model.metrics.unpricedRequests : 0
        let context = metricContext(m)
        let value = m.label(v, metrics: model.metrics, tpsScope: tpsScope)
        let action = m == .estimatedTPS ? "切换输出 Token 范围" : "查看趋势"
        let shortcut = "⌘\(m.shortcut.character) \(action)"
        return Button {
            withAnimation(animation) {
                showsQuotaChart = false
                metric = m
                if m == .estimatedTPS {
                    tpsScope = tpsScope == .all ? .over800 : .all
                    hoveredDate = nil
                }
            }
        } label: {
            tileFace(title: m.title, symbol: m.symbol,
                     value: m.label(v, compact: true, metrics: model.metrics, tpsScope: tpsScope), detail: detail,
                     indicator: on ? "checkmark" : nil, selected: on, missing: v == nil)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(m.shortcut, modifiers: .command)
        .help(Text(verbatim: ["\(m.title)：\(value)", context, shortcut].compactMap { $0 }.joined(separator: "\n")))
        .accessibilityLabel(m.title)
        .accessibilityValue(value)
        .accessibilityHint([context, "激活以" + action].compactMap { $0 }.joined(separator: "。"))
        .accessibilityAddTraits(on ? .isSelected : [])
        .overlay(alignment: .bottomLeading) {
            if unpriced > 0 {
                Button {
                    showUnpricedRequests(scroller)
                } label: {
                    HStack(spacing: 4) {
                        Text("\(unpriced.formatted()) 条未计价").lineLimit(1)
                        Image(systemName: "arrow.down").font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.caption).foregroundStyle(accent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("在下方请求记录查看未计价请求")
                .padding(.leading, 12).padding(.bottom, 11)
            }
        }
    }

    /// Six tiles share a row while each keeps `tileMinWidth`; narrower, they wrap to 3 × 2
    /// rather than squeeze, and every tile keeps the same height either way.
    private func tiles(_ scroller: ScrollViewProxy) -> some View {
        ViewThatFits(in: .horizontal) {
            Grid(horizontalSpacing: 10) {
                GridRow { ForEach(Metric.allCases) { tile($0, scroller: scroller) }; quotaTile }
            }
            .frame(idealWidth: Self.tileMinWidth * 6 + 10 * 5, maxWidth: .infinity)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { ForEach(Metric.allCases.prefix(3)) { tile($0, scroller: scroller) } }
                GridRow { ForEach(Metric.allCases.dropFirst(3)) { tile($0, scroller: scroller) }; quotaTile }
            }
        }
    }

    /// Room for a full-size value and a one-line title, so six across never crowds the metric tiles.
    private static let tileMinWidth: CGFloat = 140

    private func tileFace(title: String, symbol: String, value: String, detail: String?,
                          indicator: String?, selected: Bool = false, missing: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(selected ? accent : secondaryInk)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: indicator ?? "checkmark").font(.caption.weight(.semibold)).frame(width: 12)
                    .opacity(indicator == nil ? 0 : 1).accessibilityHidden(true)
            }
            .font(.callout.weight(.medium)).foregroundStyle(secondaryInk)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(missing ? secondaryInk : .primary)
                .lineLimit(1, reservesSpace: true).truncationMode(.middle)
            if let detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(secondaryInk)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(.rect)
        .background(.fill.quinary, in: shape)
        .overlay {
            shape.strokeBorder(selected ? accent : Color.primary.opacity(contrast == .increased ? 0.32 : 0.11),
                               lineWidth: selected ? 1.5 : 1).allowsHitTesting(false)
        }
    }

    /// The face mirrors `tile(_:)` so the six tiles have one height and one look.
    private var quotaTile: some View {
        let option = quotaOption, drop = quotaDrop(option)
        let value = quotaDropLabel(drop)
        let titleLine = option.map { "\n" + $0.title } ?? ""
        return Button {
            clearChartSelection()
            withAnimation(animation) { showsQuotaChart = true }
        } label: {
            tileFace(title: "周额度下降", symbol: "chart.line.downtrend.xyaxis", value: value,
                     detail: option?.title ?? "此范围内观测点不足", indicator: showsQuotaChart ? "checkmark" : nil,
                     selected: showsQuotaChart,
                     missing: drop == nil)
        }
        .buttonStyle(.plain).keyboardShortcut("6", modifiers: .command)
        .focusEffectDisabled()
        .help(Text(verbatim: "周额度下降：\(value)\(titleLine)\n\(quotaNote)\n⌘6 查看额度与费用趋势"))
        .accessibilityLabel("周额度下降")
        .accessibilityValue((drop == nil ? "无数据" : value) + (option.map { "，" + $0.title } ?? ""))
        .accessibilityHint(quotaNote + "。激活以查看额度与费用趋势")
        .accessibilityAddTraits(showsQuotaChart ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            if !model.quotaDepletionOptions.isEmpty {
                Menu {
                    Picker("额度账号", selection: $navigation.quotaOptionID) {
                        Text("自动（降幅最大）").tag("")
                        ForEach(model.quotaDepletionOptions) { o in Text(o.title).tag(o.id) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(secondaryInk)
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .focusEffectDisabled()
                .accessibilityLabel("切换额度账号")
                .padding(9)
            }
        }
    }

    private func chartCard(_ scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    chartHeading
                    Spacer(minLength: 0)
                    chartGroupingMenu
                    pinnedControls(scroller)
                }
                VStack(alignment: .leading, spacing: 8) { chartHeading; chartGroupingMenu; pinnedControls(scroller) }
            }
            if model.metrics.requests == 0 || model.timeline.allSatisfy({ chartMetricValue($0.metrics) == nil }) {
                ContentUnavailableView(model.metrics.requests == 0 ? "此范围暂无数据" : "\(metric.title)未知", systemImage: metric == .estimatedTPS ? metric.symbol : "moon.zzz",
                    description: Text(model.metrics.requests == 0 ? "调整时间范围或筛选条件后再试。"
                        : metric == .estimatedTPS ? "所选范围内没有达到门槛的日志或 CPA 完整耗时样本。"
                        : "所选范围内没有足够的数据来计算此指标。"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
            } else {
                chart(scroller).frame(height: 280)
                seriesLegend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Int.self) { geometry in
            UsageChartResolution.targetBucketCount(forContentWidth: Double(geometry.size.width))
        } action: { count in
            model.setChartBucketTarget(count)
        }
        .padding(18)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.32 : 0.11))
                .allowsHitTesting(false)
        }
    }

    private var chartGroupingMenu: some View {
        Menu {
            Button { model.setChartGrouping(nil) } label: {
                if model.chartGroupingOverride == nil { Label("自动", systemImage: "checkmark") }
                else { Text("自动") }
            }
            Divider()
            ForEach(UsageChartDimension.allCases) { dimension in
                Button { model.setChartGrouping(dimension) } label: {
                    if model.chartGroupingOverride == dimension { Label(dimension.label, systemImage: "checkmark") }
                    else { Text(dimension.label) }
                }
            }
        } label: {
            let current = model.chartSeriesData.grouping.label
            Label(model.chartGroupingOverride == nil ? "自动 · \(current)" : "按\(current)着色",
                  systemImage: "chart.bar.xaxis")
        }
        .menuStyle(.button).buttonStyle(.bordered).fixedSize()
        .accessibilityLabel("图表颜色分组")
        .accessibilityValue(model.chartGroupingOverride == nil
            ? "自动，按\(model.chartSeriesData.grouping.label)" : model.chartSeriesData.grouping.label)
        .help("自动按最近多选、且当前有多组数据的筛选着色；没有多选时按模型。也可指定分组。")
    }

    private var seriesLegend: some View {
        ChartSeriesLegend(title: model.chartSeriesData.grouping.label,
                          entries: model.chartSeriesData.seriesIDs.map { id in
            .init(id: id, name: seriesName(id), detailName: seriesDetailName(id), color: seriesColor(id))
        })
    }

    private func seriesColor(_ id: String) -> Color {
        ModelChartPalette.color(slot: model.chartColorSlot(for: id))
    }

    private func seriesName(_ id: String) -> String {
        switch model.chartSeriesData.grouping {
        case .model: return model.modelDisplayName(id)
        case .device:
            let name = model.deviceNames[id] ?? id
            let duplicate = model.chartSeriesData.seriesIDs.contains { $0 != id && (model.deviceNames[$0] ?? $0) == name }
            return duplicate ? "\(name) · \(id.prefix(6))" : name
        case .account:
            return UsageAccountFacet(id: id).map(model.accountFilterOptionLabel) ?? "账号未记录"
        case .agent: return UsageAgentGroup(rawValue: id)?.label ?? id
        case .requestedTier: return ServiceTier(rawValue: id)?.label ?? id
        case .status: return RequestStatusFacet(id: id)?.label ?? id
        }
    }

    private func seriesDetailName(_ id: String) -> String {
        model.chartSeriesData.grouping == .model ? model.modelFilterOptionLabel(id) : seriesName(id)
    }

    private var chartHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(metric.title)趋势").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(caption).font(.callout).foregroundStyle(secondaryInk)
        }
    }

    /// Appears only for a pinned bucket; hovering never touches the request list.
    @ViewBuilder private func pinnedControls(_ scroller: ScrollViewProxy) -> some View {
        if let pinned = pinnedBucket {
            HStack(spacing: 8) {
                Text(bucketTitle(pinned)).font(.callout).monospacedDigit()
                    .foregroundStyle(secondaryInk).lineLimit(1)
                Button("查看此时段请求", systemImage: "list.bullet.rectangle") {
                    showRequests(in: pinned, scroller: scroller)
                }
                .buttonStyle(.bordered)
                .help("下方请求记录只显示 \(bucketTitle(pinned)) 的请求。")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chartMetricValue(_ metrics: UsageMetrics) -> Double? {
        metric.value(metrics, tpsScope: tpsScope)
    }

    private func chart(_ scroller: ScrollViewProxy) -> some View {
        let selection = selected
        let pinned = pinnedBucket
        let hovered = bucket(at: hoveredDate)
        let axisBuckets = chartAxisBuckets
        let axisDates = axisBuckets.map(chartXPosition)
        let domain = chartDomain
        let data = model.chartSeriesData
        let columns = metric.usesColumns ? data.columns(value: chartMetricValue) : []
        let lines = metric.usesColumns ? [] : data.lines(value: chartMetricValue)
        let rateScale = metric.usesColumns ? nil
            : RateChartScale.make(metric == .cache ? .cacheRate : .throughput,
                                  values: lines.map(\.value), automatic: model.automaticRateYAxis)
        let focusedGroups = hovered.map { data.groups(at: $0.date) } ?? []
        let selectedEntries = chartTipEntries(focusedGroups)
        return withRateScale(Chart {
            if metric.usesColumns {
                ForEach(columns) { column in
                    let b = column.bucket
                    let bounds = columnBounds(date: b.date, end: b.endDate)
                    RectangleMark(xStart: .value("起始", bounds.lowerBound), xEnd: .value("结束", bounds.upperBound),
                                  yStart: .value(metric.title, column.lower), yEnd: .value(metric.title, column.upper))
                        .cornerRadius(data.seriesIDs.count == 1 ? 3 : 0)
                        .foregroundStyle(seriesColor(b.seriesIdentity))
                        .accessibilityLabel(chartSeriesAccessibilityLabel(b))
                        .accessibilityValue(metric.label(column.value))
                }
            } else {
                ForEach(lines) { point in
                    let b = point.bucket
                    let color = seriesColor(b.seriesIdentity)
                    let emphasized = b.date == selection?.date || b.date == pinned?.date
                    let position = chartXPosition(date: b.date, end: b.endDate)
                    LineMark(x: .value("时间", position), y: .value(metric.title, point.value), series: .value("连续区间", point.series))
                        .foregroundStyle(color)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, dash: metric == .estimatedTPS ? [5, 4] : []))
                        .interpolationMethod(.monotone).accessibilityHidden(true)
                    PointMark(x: .value("时间", position), y: .value(metric.title, point.value))
                        .foregroundStyle(color).symbolSize(emphasized ? 48 : 18)
                        .accessibilityLabel(chartSeriesAccessibilityLabel(b))
                        .accessibilityValue(metric.label(point.value, metrics: b.metrics, tpsScope: tpsScope))
                }
            }
            if let b = pinned, b.date != hovered?.date {
                RuleMark(x: .value("选中", chartXPosition(b)))
                    .foregroundStyle(Color.primary.opacity(0.40)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
            if let b = hovered {
                RuleMark(x: .value("悬停", chartXPosition(b)))
                    .foregroundStyle(Color.primary.opacity(0.45)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartValueTip(
                            title: bucketTitle(b),
                            value: metric.label(chartMetricValue(b.metrics), metrics: b.metrics, tpsScope: tpsScope),
                            note: metric == .cost ? unpricedNote(b.metrics) : nil,
                            entries: Array(selectedEntries.prefix(5)),
                            additionalCount: max(0, selectedEntries.count - 5)
                        )
                    }
            }
        }, rateScale)
        .chartXScale(domain: domain)
        .accessibilityLabel("\(metric.title)趋势")
        .accessibilityHint("可使用方向键浏览各时段，按回车查看该时段的请求")
        .focusable()
        .focused($chartFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { stepChart(-1); return .handled }
        .onKeyPress(.rightArrow) { stepChart(1); return .handled }
        .onKeyPress(.return) {
            guard let pinned = pinnedBucket else { return .ignored }
            showRequests(in: pinned, scroller: scroller)
            return .handled
        }
        .onKeyPress(.escape) {
            guard selectedDate != nil else { return .ignored }
            selectedDate = nil
            return .handled
        }
        .chartOverlay { chartProxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = chartProxy.plotFrame else { hoveredDate = nil; return }
                            let plot = geometry[frame]
                            hoveredDate = plot.contains(location) ? chartProxy.value(atX: location.x - plot.minX, as: Date.self) : nil
                        case .ended: hoveredDate = nil
                        }
                    }
                    .onTapGesture { location in
                        pin(at: location, chart: chartProxy, geometry: geometry)
                    }
                if let frame = chartProxy.plotFrame {
                    let plot = geometry[frame]
                    let labels = positionedAxisLabels(axisBuckets, proxy: chartProxy, plot: plot, width: geometry.size.width)
                    ForEach(labels) { label in
                        Text(label.text)
                            .font(.system(size: Self.axisLabelSize).monospacedDigit())
                            .foregroundStyle(secondaryInk)
                            .fixedSize()
                            .position(x: label.center, y: plot.maxY + 12)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .chartYAxis {
            if let rateScale {
                AxisMarks(position: .leading, values: rateScale.ticks) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(metric.axisText(d)).foregroundStyle(secondaryInk) } }
                }
            } else {
                AxisMarks(position: .leading) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(metric.axisText(d)).foregroundStyle(secondaryInk) } }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            }
        }
        .padding(.bottom, 22)
    }

    @ViewBuilder private func withRateScale<V: View>(_ chart: V, _ scale: RateChartScale?) -> some View {
        if let scale { chart.chartYScale(domain: scale.domain) }
        else { chart }
    }

    /// A click pins the bucket under the pointer; clicking it again, or outside the plot, unpins.
    private func pin(at location: CGPoint, chart: ChartProxy, geometry: GeometryProxy) {
        chartFocused = true
        guard let frame = chart.plotFrame else { return }
        let plot = geometry[frame]
        guard plot.contains(location),
              let bucket = bucket(at: chart.value(atX: location.x - plot.minX, as: Date.self)) else {
            selectedDate = nil
            return
        }
        selectedDate = selectedDate == bucket.date ? nil : bucket.date
    }

    private var requestScopeLabel: String? { unpricedOnly ? "未计价" : requestWindow?.title }

    private func clearRequestScope() {
        unpricedOnly = false
        requestWindow = nil
    }

    private func showUnpricedRequests(_ scroller: ScrollViewProxy) {
        requestWindow = nil
        unpricedOnly = true
        unpricedDrillDownRevision &+= 1
        scrollToRequests(scroller)
    }

    private func showRequests(in bucket: UsageBucket, scroller: ScrollViewProxy) {
        unpricedOnly = false
        requestWindow = RequestWindow(title: bucketTitle(bucket), start: bucket.date, end: bucketEnd(bucket))
        scrollToRequests(scroller)
    }

    private func scrollToRequests(_ scroller: ScrollViewProxy) {
        withAnimation(animation) { scroller.scrollTo("requests", anchor: .top) }
    }

    private func clearChartSelection() {
        selectedDate = nil
        hoveredDate = nil
        requestWindow = nil
    }

    /// `filteredRequests` is newest first, so one bucket is a contiguous run found by
    /// binary search; hover re-renders don't rescan the whole list.
    private var historyRequests: [UsageRequest] {
        if unpricedOnly { return model.unpricedDashboardRequests }
        let rows = model.filteredRequests
        guard let window = requestWindow else { return rows }
        func firstIndex(before date: Date) -> Int {
            var low = 0, high = rows.count
            while low < high {
                let mid = (low + high) / 2
                if rows[mid].timestamp < date { high = mid } else { low = mid + 1 }
            }
            return low
        }
        let newest = firstIndex(before: window.end)
        let oldest = firstIndex(before: window.start)
        return newest < oldest ? Array(rows[newest..<oldest]) : []
    }

    private struct PositionedAxisLabel: Identifiable {
        let id: Date
        let text: String
        let center: CGFloat
    }

    private static let axisLabelSize: CGFloat = 11

    private func positionedAxisLabels(_ buckets: [UsageBucket], proxy: ChartProxy, plot: CGRect, width: CGFloat) -> [PositionedAxisLabel] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Self.axisLabelSize, weight: .regular)
        var nextLeading: CGFloat = 0
        return buckets.compactMap { bucket in
            let date = chartXPosition(bucket)
            guard let x = proxy.position(forX: date) else { return nil }
            let text = axisLabel(bucket.date)
            let halfWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) / 2 + 1
            let center = plot.minX + x
            guard center - halfWidth >= nextLeading, center + halfWidth <= width else { return nil }
            nextLeading = center + halfWidth + 10
            return PositionedAxisLabel(id: bucket.date, text: text, center: center)
        }
    }

    private var chartDomain: ClosedRange<Date> {
        guard let first = model.timeline.first, let last = model.timeline.last else {
            let now = Date.now
            return now...now.addingTimeInterval(3600)
        }
        if metric.usesColumns {
            return columnSlot(date: first.date, end: first.endDate).start...columnSlot(date: last.date, end: last.endDate).end
        }
        return first.date...bucketEnd(last)
    }

    private var chartAxisBuckets: [UsageBucket] {
        let timeline = model.timeline
        let limit = model.timelineInterval.isSubdaily ? 6 : 7
        guard timeline.count > limit else { return timeline }
        // A constant stride leaves a predictable cadence on longer ranges.
        // Center the run in the domain so wide hourly labels fit at both ends.
        let step = (timeline.count + limit - 1) / limit
        let count = timeline.count / step
        let first = (timeline.count - 1 - (count - 1) * step) / 2
        return (0..<count).map { timeline[first + $0 * step] }
    }

    private func bucketEnd(_ bucket: UsageBucket) -> Date {
        bucketEnd(date: bucket.date, end: bucket.endDate)
    }

    private func bucketEnd(date: Date, end: Date?) -> Date {
        if let end, end > date { return end }
        return model.timelineInterval.interval(containing: date, calendar: model.displayCalendar)?.end
            ?? date.addingTimeInterval(3600)
    }

    private func chartXPosition(_ bucket: UsageBucket) -> Date {
        chartXPosition(date: bucket.date, end: bucket.endDate)
    }

    private func chartXPosition(date: Date, end: Date?) -> Date {
        if metric.usesColumns {
            let slot = columnSlot(date: date, end: end)
            return slot.start.addingTimeInterval(slot.duration / 2)
        }
        return date.addingTimeInterval(bucketEnd(date: date, end: end).timeIntervalSince(date) / 2)
    }

    /// Geometry uses a full calendar slot; bucketEnd remains the actual query cutoff.
    private func columnSlot(date: Date, end: Date?) -> DateInterval {
        model.timelineInterval.interval(containing: date, calendar: model.displayCalendar)
            ?? DateInterval(start: date, end: bucketEnd(date: date, end: end))
    }

    private func columnBounds(date: Date, end: Date?) -> ClosedRange<Date> {
        let slot = columnSlot(date: date, end: end)
        let inset = slot.duration * (model.timeline.count == 1 ? 0.27 : 0.13)
        return slot.start.addingTimeInterval(inset)...slot.end.addingTimeInterval(-inset)
    }

    private func axisLabel(_ date: Date) -> String {
        let calendar = model.displayCalendar
        switch model.timelineInterval {
        case .hour, .hours:
            if let first = model.timeline.first, let last = model.timeline.last,
               calendar.isDate(first.date, inSameDayAs: last.date) {
                return DashboardDates.hourLabel(date, calendar: calendar)
            }
            return DashboardDates.dayLabel(date, calendar: calendar) + " " + DashboardDates.hourLabel(date, calendar: calendar)
        case .day, .days, .week: return DashboardDates.dayLabel(date, calendar: calendar)
        case .month: return DashboardDates.monthLabel(date, calendar: calendar)
        case .quarter: return DashboardDates.quarterLabel(date, calendar: calendar)
        case .year: return model.formatDate(date, as: .dateTime.year().locale(DashboardDates.locale))
        }
    }

    private func bucketTitle(_ bucket: UsageBucket) -> String {
        let calendar = model.displayCalendar
        switch model.timelineInterval {
        case .hour, .hours:
            let end = bucketEnd(bucket)
            let startLabel = DashboardDates.dayLabel(bucket.date, calendar: calendar) + " "
                + DashboardDates.hourLabel(bucket.date, calendar: calendar)
            let endDate = calendar.isDate(bucket.date, inSameDayAs: end) ? "" : DashboardDates.dayLabel(end, calendar: calendar) + " "
            return startLabel + "–" + endDate + DashboardDates.hourLabel(end, calendar: calendar)
        case .day:
            return model.formatDate(bucket.date, as: .dateTime.year().month().day().weekday().locale(DashboardDates.locale))
        case .days, .week:
            let from = model.range == .custom ? max(bucket.date, model.customHours.lowerBound) : bucket.date
            let through = max(from, (bucket.endDate ?? bucket.date).addingTimeInterval(-1))
            return DashboardDates.dayLabel(from, calendar: calendar) + "–" + DashboardDates.dayLabel(through, calendar: calendar)
        case .month, .quarter, .year:
            return axisLabel(bucket.date)
        }
    }

    private func chartSeriesAccessibilityLabel(_ bucket: UsageSeriesBucket) -> String {
        let date = bucketTitle(UsageBucket(date: bucket.date, metrics: bucket.metrics, endDate: bucket.endDate))
        return "\(date)，\(seriesDetailName(bucket.seriesIdentity))"
    }

    private func chartTipEntries(_ buckets: [UsageSeriesBucket]) -> [ChartValueTip.Entry] {
        let ranked = buckets.map { ($0, chartMetricValue($0.metrics)) }.sorted { left, right in
            let a = left.1 ?? -.infinity, b = right.1 ?? -.infinity
            return a == b ? left.0.seriesIdentity < right.0.seriesIdentity : a > b
        }
        return ranked.map { bucket, value in
            ChartValueTip.Entry(id: bucket.seriesIdentity,
                                name: seriesName(bucket.seriesIdentity),
                                value: metric == .cost && value == nil && bucket.metrics.unpricedRequests > 0
                                    ? "未计价" : metric.label(value, compact: true, metrics: bucket.metrics, tpsScope: tpsScope),
                                color: seriesColor(bucket.seriesIdentity))
        }
    }

    private func bucket(at date: Date?) -> UsageBucket? {
        if metric.usesColumns, let date {
            return model.timeline.last { bucket in
                let slot = columnSlot(date: bucket.date, end: bucket.endDate)
                return slot.start <= date && date < slot.end
            }
        }
        guard let d = date, let bucket = model.timeline.last(where: { $0.date <= d }),
              d < bucketEnd(bucket) else { return nil }
        return bucket
    }

    /// Keyboard navigation may use the pinned bucket. Only hover shows the tip.
    private var selected: UsageBucket? { bucket(at: hoveredDate ?? selectedDate) }
    private var pinnedBucket: UsageBucket? { bucket(at: selectedDate) }

    private func stepChart(_ direction: Int) {
        let buckets = model.timeline
        guard !buckets.isEmpty else { return }
        let index = selected.flatMap { bucket in buckets.firstIndex { $0.date == bucket.date } }
        let next = index.map { min(max(0, $0 + direction), buckets.count - 1) }
            ?? (direction < 0 ? buckets.count - 1 : 0)
        hoveredDate = nil
        selectedDate = buckets[next].date
    }

    private var caption: String {
        let unknown = model.timeline.count { $0.metrics.requests > 0 && chartMetricValue($0.metrics) == nil }
        return model.timelineInterval.label + (unknown > 0 ? " · \(unknown) 个时段未知" : "")
    }

    private func metricContext(_ metric: Metric) -> String? {
        let metrics = model.metrics
        switch metric {
        case .tokens, .requests: return nil
        case .cost:
            let coverage = unpricedNote(metrics)
            let cache = metrics.cacheWriteFallbackRequests > 0 ? "部分缓存写入按通用费率估算" : nil
            let context = [coverage, cache].compactMap { $0 }
            return context.isEmpty ? (metrics.cost == nil ? "暂无可用费用" : "按 API 价目计算") : context.joined(separator: "；")
        case .cache: return metrics.cacheRate == nil ? "无可计算的输入" : "缓存读取占输入比例"
        case .estimatedTPS:
            let scope = tpsScope == .over800 ? "输出 > 800 Token" : "全部有效样本"
            return scope + "；" + estimatedTPSHelp(for: metrics, scope: tpsScope)
        }
    }

    /// The picked channel, else the largest drop; options arrive sorted by drop, largest first.
    private var quotaOption: QuotaDepletionOption? {
        let options = model.quotaDepletionOptions
        return options.first { $0.id == quotaOptionID } ?? options.first
    }

    /// Only an observed drop gets a number; a channel without enough readings shows "—", never 0%.
    private func quotaDrop(_ o: QuotaDepletionOption?) -> Double? {
        guard let o, o.observedIntervals > 0, o.consumedPercent.isFinite else { return nil }
        return o.consumedPercent
    }

    /// `consumedPercent` is in percentage points, so 18.4 reads "18.4%"; summed across resets it can pass 100%.
    private func quotaDropLabel(_ v: Double?) -> String {
        v.map { ($0 / 100).formatted(.percent.precision(.fractionLength(1))) } ?? "—"
    }

    /// What the quota tile measures, for its tooltip and VoiceOver.
    private var quotaNote: String {
        let basis = "按实际观测计算：同一周额度周期内官方使用百分比的增量，跨重置分段相加，可超过 100%；额度重置不会被当成下降"
        guard let o = quotaOption, quotaDrop(o) != nil else {
            return "所选时间范围内没有观测到足够的额度读数点，无法计算。" + basis
        }
        let pick = o.id == quotaOptionID ? "手动选择" : "自动选择降幅最大的渠道"
        return "\(o.cycles) 个周期 · \(o.observedIntervals) 个观测区间 · \(pick)。" + basis
    }

    private func unpricedNote(_ metrics: UsageMetrics) -> String? {
        metrics.unpricedRequests > 0 ? "\(metrics.unpricedRequests.formatted()) 次未计价" : nil
    }

}

/// A macOS Menu closes after each action. A native checkbox popover keeps the
/// list open so several values can be checked in one pass.
private struct FacetToggle {
    let label: String
    let isOn: Binding<Bool>
}

private struct DashboardFacetPicker<Value: Hashable>: View {
    let title: String
    let icon: String
    @Binding var selection: Set<Value>
    let values: [Value]
    let name: (Value) -> String
    let optionName: (Value) -> String
    var extraFilter: FacetToggle? = nil
    @State private var presented = false
    @State private var query = ""

    private var matching: [Value] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return values }
        return values.filter { optionName($0).localizedCaseInsensitiveContains(needle) }
    }

    /// The extra toggle still filters, but it is a standing preference rather than a pick:
    /// counts, badges and "全部" only concern `selection`.
    private var excludesExtra: Bool { extraFilter?.isOn.wrappedValue == true }

    var body: some View {
        let on = !selection.isEmpty
        let current = selection.count > 1 ? "\(title) · \(selection.count) 项" : selection.first.map(name) ?? title
        let names = values.filter { selection.contains($0) }.prefix(8).map(optionName)
        let summary = names.joined(separator: "、") + (selection.count > names.count ? "，另 \(selection.count - names.count) 项" : "")
        let extraNote = excludesExtra ? extraFilter.map { "已开启：" + $0.label } : nil
        Button {
            query = ""
            presented.toggle()
        } label: {
            // An explicit 4 pt run; Label's default icon gap reads detached in a bordered button.
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.circle.fill" : icon).accessibilityHidden(true)
                Text(verbatim: current).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: on ? 130 : nil)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).accessibilityHidden(true)
            }
        }
        .buttonStyle(.bordered)
        .disabled(values.isEmpty && extraFilter == nil)
        .accessibilityLabel(title)
        .accessibilityValue([on ? "已选 \(selection.count) 项：\(summary)" : "全部", extraNote]
            .compactMap { $0 }.joined(separator: "；"))
        .accessibilityHint("打开\(title)勾选清单")
        .help([on ? "\(title)：\(summary)" : "筛选\(title)，可勾选多项", extraNote]
            .compactMap { $0 }.joined(separator: "\n"))
        .popover(isPresented: $presented, arrowEdge: .bottom) { options }
    }

    private var options: some View {
        let entries = matching
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("全部\(title)") { selection = [] }
                    .disabled(selection.isEmpty)
                    .help(extraFilter == nil ? "清除本栏已选项" : "清除本栏已选项，不改变下方排除设置")
            }
            if let extraFilter {
                Toggle(extraFilter.label, isOn: extraFilter.isOn).toggleStyle(.checkbox)
            }
            if values.count >= 12 {
                TextField("搜索\(title)", text: $query).textFieldStyle(.roundedBorder)
            }
            Divider()
            if entries.isEmpty {
                Text("没有匹配项").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries, id: \.self) { value in
                            Toggle(isOn: Binding(get: { selection.contains(value) }, set: { checked in
                                if checked { selection.insert(value) } else { selection.remove(value) }
                            })) {
                                Text(verbatim: optionName(value)).lineLimit(1).truncationMode(.middle)
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
                            .help(optionName(value))
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(height: min(300, CGFloat(entries.count * 25 - 2)))
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }
}

private enum DashboardDates {
    static let locale = Locale(identifier: "zh_CN")

    static func dayLabel(_ date: Date, includeYear: Bool = false, calendar: Calendar) -> String {
        let style = Date.FormatStyle.dateTime.month().day().locale(locale)
        return UsageDisplayTime.format(date, as: includeYear ? style.year() : style, calendar: calendar)
    }

    static func monthLabel(_ date: Date, calendar: Calendar) -> String {
        UsageDisplayTime.format(date, as: .dateTime.year().month().locale(locale), calendar: calendar)
    }

    static func quarterLabel(_ date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        let quarter = calendar.component(.quarter, from: date)
        return "\(year) 年 Q\(quarter)"
    }

    static func hourLabel(_ date: Date, calendar: Calendar) -> String {
        let minutes = minuteOfDay(date, calendar: calendar)
        let clock = String(format: "%02d:%02d", minutes / 60, minutes % 60)
        // Make repeated labels distinguishable on the day clocks go back.
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let repeated = [-3600.0, -1800.0, 1800.0, 3600.0].contains { seconds in
            let other = date.addingTimeInterval(seconds)
            return calendar.timeZone.secondsFromGMT(for: other) != offset
                && calendar.isDate(date, inSameDayAs: other) && minutes == minuteOfDay(other, calendar: calendar)
        }
        guard repeated else { return clock }
        let offsetLabel = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 3600, abs(offset) / 60 % 60)
        return clock + " " + offsetLabel
    }

    /// The last minute of the hour that starts at `hour`, e.g. 12:00 → "12:59".
    /// Custom ranges include their end hour, so labels name its last minute.
    static func lastMinuteLabel(_ hour: Date, calendar: Calendar) -> String {
        let end = UsageBucketInterval.hour.interval(containing: hour, calendar: calendar)?.end
            ?? hour.addingTimeInterval(3600)
        return hourLabel(end.addingTimeInterval(-60), calendar: calendar)
    }

    /// Hour columns from `start` through `end`, both included.
    static func hourSpan(_ start: Date, through end: Date, calendar: Calendar) -> String {
        let next = UsageBucketInterval.hour.interval(containing: end, calendar: calendar)?.end
            ?? end.addingTimeInterval(3600)
        let minutes = max(0, Int((next.timeIntervalSince(start) / 60).rounded()))
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return "\(remainder) 分钟" }
        return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分钟"
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func rangeLabel(_ hours: ClosedRange<Date>, calendar: Calendar) -> String {
        let start = hours.lowerBound, end = hours.upperBound
        let currentYear = calendar.component(.year, from: .now)
        let startYear = calendar.component(.year, from: start), endYear = calendar.component(.year, from: end)
        let showYear = startYear != currentYear || endYear != currentYear
        let from = dayLabel(start, includeYear: showYear, calendar: calendar) + " " + hourLabel(start, calendar: calendar)
        let to = lastMinuteLabel(end, calendar: calendar)
        if calendar.isDate(start, inSameDayAs: end) { return from + "–" + to }
        return from + " – " + dayLabel(end, includeYear: showYear, calendar: calendar) + " " + to
    }
}

private struct CustomHoursPopover: View {
    private enum Endpoint: String, CaseIterable {
        case start, end
        var label: String { self == .start ? "开始" : "结束" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: Endpoint = .start
    @State private var start: Date
    @State private var end: Date
    let apply: (ClosedRange<Date>) -> Void
    @Environment(\.calendar) private var calendar

    init(hours: ClosedRange<Date>, apply: @escaping (ClosedRange<Date>) -> Void) {
        _start = State(initialValue: hours.lowerBound)
        _end = State(initialValue: hours.upperBound)
        self.apply = apply
    }

    private var active: Binding<Date> { endpoint == .start ? $start : $end }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义时间").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 12) {
                endpointSummary(.start, date: start)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    .padding(.top, 4).accessibilityHidden(true)
                endpointSummary(.end, date: end)
            }
            Picker("正在编辑", selection: $endpoint) {
                ForEach(Endpoint.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(alignment: .top, spacing: 18) {
                DatePicker(endpoint.label + "日期", selection: day, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().fixedSize()
                VStack(alignment: .leading, spacing: 6) {
                    Text(endpoint == .start ? "开始小时" : "结束小时（含）").font(.caption).foregroundStyle(.secondary)
                    Picker(endpoint.label + "小时", selection: active) {
                        ForEach(UsageBucketInterval.localHours(on: active.wrappedValue, calendar: calendar), id: \.start) { hour in
                            Text(DashboardDates.hourLabel(hour.start, calendar: calendar)).tag(hour.start)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text(start > end ? "结束小时不能早于开始小时。"
                 : "使用设置的时区，包含结束小时（至 \(DashboardDates.lastMinuteLabel(end, calendar: calendar))），共 \(DashboardDates.hourSpan(start, through: end, calendar: calendar))。")
                .font(.caption).foregroundStyle(start > end ? Color.red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    if start <= end { apply(start...end) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(start > end)
            }
        }
        .padding(16)
        .frame(width: 306)
    }

    private var day: Binding<Date> {
        Binding {
            calendar.startOfDay(for: active.wrappedValue)
        } set: { newDay in
            let old = active.wrappedValue
            guard !calendar.isDate(old, inSameDayAs: newDay) else { return }
            let minute = DashboardDates.minuteOfDay(old, calendar: calendar)
            let offset = calendar.timeZone.secondsFromGMT(for: old)
            let options = UsageBucketInterval.localHours(on: newDay, calendar: calendar).map(\.start)
            let exact = options.first {
                DashboardDates.minuteOfDay($0, calendar: calendar) == minute
                    && calendar.timeZone.secondsFromGMT(for: $0) == offset
            }
            if let next = exact ?? options.first(where: { DashboardDates.minuteOfDay($0, calendar: calendar) >= minute }) ?? options.last {
                active.wrappedValue = next
            }
        }
    }

    /// The end shows its whole hour, "12:00–12:59", so the picker's "12:00" reads as included.
    private func endpointSummary(_ item: Endpoint, date: Date) -> some View {
        let hour = DashboardDates.hourLabel(date, calendar: calendar)
        return VStack(alignment: .leading, spacing: 3) {
            Text(item.label).font(.caption).foregroundStyle(.secondary)
            Text(DashboardDates.dayLabel(date, includeYear: true, calendar: calendar))
            Text(item == .end ? hour + "–" + DashboardDates.lastMinuteLabel(date, calendar: calendar) : hour)
                .monospacedDigit()
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ChartValueTip: View {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let value: String
        let color: Color
    }

    let title: String
    let value: String
    let note: String?
    let entries: [Entry]
    let additionalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline).monospacedDigit()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if !entries.isEmpty {
                Divider().padding(.vertical, 3)
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Circle().fill(entry.color).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 5)
                        Text(entry.value).monospacedDigit().lineLimit(1)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
                if additionalCount > 0 {
                    Text("另有 \(additionalCount) 组").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: entries.isEmpty ? nil : 210, alignment: .leading)
        .fixedSize(horizontal: entries.isEmpty, vertical: true)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
