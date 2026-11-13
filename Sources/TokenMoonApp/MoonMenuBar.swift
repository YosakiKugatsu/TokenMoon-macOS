// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import TokenMoonCore

// Neutral surfaces; one muted accent for the orbit and today's bar.
private let orbitAccent = Color.indigo.opacity(0.7)
private let headlineFont = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
private let numberFont = Font.system(size: 12, weight: .medium).monospacedDigit()

private func panelSecondary(_ contrast: ColorSchemeContrast) -> Color {
    .primary.opacity(contrast == .increased ? 1 : 0.77)
}

/// A crescent with a faint orbit and a small satellite in its embrace.
struct MoonMark: View {
    var size: CGFloat = 16
    var tint: Color = .primary
    var orbit: Color = .primary.opacity(0.45)

    var body: some View {
        Canvas { context, _ in
            let s = size, c = CGPoint(x: s * 0.44, y: s * 0.56)
            context.drawLayer { moon in
                moon.fill(Path(ellipseIn: CGRect(x: c.x - s * 0.32, y: c.y - s * 0.32, width: s * 0.64, height: s * 0.64)), with: .color(tint))
                moon.blendMode = .destinationOut
                moon.fill(Path(ellipseIn: CGRect(x: c.x - s * 0.12, y: c.y - s * 0.46, width: s * 0.56, height: s * 0.56)), with: .color(.black))
            }
            func point(_ angle: Double) -> CGPoint { CGPoint(x: c.x + s * 0.44 * cos(angle), y: c.y + s * 0.44 * sin(angle)) }
            var arc = Path()
            arc.addLines((0...14).map { point(-1.9 + Double($0) * 0.13) })
            context.stroke(arc, with: .color(orbit), style: StrokeStyle(lineWidth: max(1, s * 0.06), lineCap: .round))
            let dot = point(-0.75)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - s * 0.08, y: dot.y - s * 0.08, width: s * 0.16, height: s * 0.16)), with: .color(orbit))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Status bar

/// Compact two-line readouts, with the label and unit lighter than the digits.
struct MoonStatusReadout: Equatable {
    private let glyph: MoonStatusGlyph
    let accessibilityLabel: String

    @MainActor init(model: AppModel) {
        let thickness = NSStatusBar.system.thickness
        let height = thickness > 0 ? thickness : 22
        switch model.menuBarDisplayMode {
        case .icon:
            glyph = MoonStatusGlyph(metrics: [], height: height)
            accessibilityLabel = "TokenMoon"
        case .quota:
            let quota = MenuBarQuotaPresentation(accounts: model.quotaAccounts, source: model.menuBarQuotaSource,
                                                isRefreshing: model.isQuotaRefreshing, now: .now)
            glyph = MoonStatusGlyph(metrics: quota.metrics, height: height)
            accessibilityLabel = quota.accessibilityLabel
        case .usage:
            self = Self.usage(model: model, height: height)
        }
    }

    private init(glyph: MoonStatusGlyph, accessibilityLabel: String) {
        self.glyph = glyph
        self.accessibilityLabel = accessibilityLabel
    }

    /// Numeric mode: the two user-picked metrics, without the crescent.
    @MainActor private static func usage(model: AppModel, height: CGFloat) -> Self {
        let recent = model.last24HourMetrics
        let slots = [model.menuBarPrimaryMetric, model.menuBarSecondaryMetric]
        // The readout shares the popup's 本机 / 全部 source, so say which one it reads.
        let source = model.quickUsageScope == .local ? "on this Mac" : "across all devices"
        let values = model.menuTrendTokens.map(Double.init)
        let peak = max(values.max() ?? 0, 1)
        let trend = model.showsMenuTrend
            ? values.map { max(2, Int((20 * $0 / peak).rounded())) }
            : nil
        let spoken = slots.map { $0.accessibilityValue(for: recent) }.joined(separator: ", ")
        return Self(glyph: MoonStatusGlyph(metrics: slots.map { $0.readout(for: recent) },
                                         trend: trend, height: height, showsIcon: false),
                    accessibilityLabel: "TokenMoon, last 24 hours \(source), \(spoken)")
    }

    func hasSameImage(as previous: Self?) -> Bool { previous?.glyph == glyph }

    @MainActor func image() -> NSImage { glyph.image() }
}

// MARK: - Panel

/// The 380 pt anchored panel: header tools, a rolling 24-hour summary and trend, a usage breakdown
/// and the official allowance. In quota mode the allowance card comes first.
struct MoonQuickPanel: View {
    @Bindable var model: AppModel
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var measuredHeight: CGFloat?

    var body: some View {
        let usage = model.quickMetrics
        let bins = model.quickTimeline
        let title = model.quickSelectedBin.map { timeSpan($0, full: false) } ?? "近 24 小时"
        let maximum = max(250, (NSScreen.main?.visibleFrame.height ?? 820) - 110)
        // The menu bar shows allowance in quota mode, so the popup opens on the same reading.
        let quotaFirst = model.menuBarDisplayMode == .quota
        VStack(spacing: 0) {
            header.padding(.leading, 16).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 10)
            ScrollView {
              VStack(spacing: 8) {
                if let notice = panelNotice(now: .now) {
                    noticeRow(notice)
                }
                if quotaFirst {
                    QuotaMiniPanel(model: model)
                }
                QuietCard(title: title, trailing: "\(usage.requests) 次请求",
                          filter: model.quickModelFilter.map(model.modelDisplayName),
                          filterID: model.quickModelFilter, clearFilter: { model.clearQuickModel() },
                          accessoryBesideTitle: true) {
                    if !model.quickShowsLast24Hours {
                        Button { model.showQuickLast24Hours() } label: {
                            Label("近 24 小时", systemImage: "arrow.left")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.fill.tertiary, in: Capsule())
                                .contentShape(.capsule)
                                .fixedSize()
                        }
                        .buttonStyle(.borderless)
                        .help("返回滚动的近 24 小时")
                        .accessibilityLabel("返回近 24 小时")
                    }
                } content: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        summaryMetric("Token 用量", value: compactTokenCount(usage.tokens), help: "\(usage.tokens.formatted()) Token")
                        let cost = roundedUSDCostDigits(usage.cost)
                        summaryMetric("等效费用", value: cost ?? "—", suffix: cost.map { _ in "$" },
                                      help: "已计价请求合计：" + apiCostLabel(usage.cost, missing: "未知"))
                    }
                    HStack(spacing: 0) {
                        stat("缓存命中", usage.cacheRate.map { "\(Int(($0 * 100).rounded()))%" })
                        stat("估算 TPS", usage.estimatedTPS.map { _ in estimatedTPSLabel(for: usage) },
                             help: estimatedTPSHelp(for: usage))
                        stat("单次 Token", usage.requests > 0 ? compactTokenCount(usage.tokens / Int64(usage.requests)) : nil,
                             help: "每次请求的平均 Token 数")
                    }
                }
                let trendTotal = model.quickShowsLast24Hours ? nil : "共 " + compactTokenCount(model.quickTrendMetrics.tokens) + " Token"
                QuietCard(title: "近 24 小时趋势", trailing: trendTotal) {
                    rollingChart(bins)
                }
                QuietCard(title: "\(model.quickUsageDimension.label)排行") {
                    breakdown
                }
                if !quotaFirst {
                    QuotaMiniPanel(model: model)
                }
              }
              .padding(.horizontal, 12).padding(.bottom, 12)
              .fixedSize(horizontal: false, vertical: true)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(measuredHeight ?? 590, maximum))
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshQuickWindow() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            MoonMark(size: 20, orbit: orbitAccent)
            Text("TokenMoon").font(.system(size: 15, weight: .semibold)).fixedSize()
            Spacer(minLength: 4)
            ScopeToggle(selection: $model.quickUsageScope)
                .help(scopeHelp)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    tool("arrow.clockwise", "刷新 (⌘R)", busy: model.isRefreshing) { model.refresh() }
                    tool("arrow.triangle.2.circlepath", hasSyncTarget ? "同步 (⇧⌘S)" : "未配置 WebDAV 同步",
                         help: syncHelp, busy: model.isSyncing) { model.sync() }
                        .disabled(!hasSyncTarget)
                    tool("macwindow", "打开主窗口", action: openDashboard)
                    tool("gearshape", "设置 (⌘,)", action: openSettings)
                }
            }
        }
    }

    private var hasSyncTarget: Bool {
        !model.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The scope picks the source for the menu bar readout and this panel alike.
    private var scopeHelp: String {
        let calendar = model.displayCalendar
        var lines = ["切换菜单栏和浮窗的用量来源。官方额度始终来自本机已登录的账号。"]
        if let last = model.lastCollection {
            lines.append("本机采集于 " + statusClockLabel(last, calendar: calendar))
        }
        if hasSyncTarget {
            lines.append(model.lastSync.map { "其他设备同步于 " + statusClockLabel($0, calendar: calendar) } ?? "其他设备尚未同步")
        }
        return lines.joined(separator: "\n")
    }

    private var syncHelp: String {
        guard hasSyncTarget else { return "未配置 WebDAV 同步" }
        guard let last = model.lastSync else { return "同步 (⇧⌘S)\n尚未同步" }
        return "同步 (⇧⌘S)\n上次同步 " + statusClockLabel(last, calendar: model.displayCalendar)
    }

    // MARK: Notice

    private struct PanelNotice {
        let message: String
        let detail: String
        let action: String
        let busy: Bool
        let perform: @MainActor () -> Void
    }

    /// Shown only when the numbers below can't be trusted as current: local collection
    /// failed, or 全部 relies on a sync that failed, never ran, or fell behind its schedule.
    private func panelNotice(now: Date) -> PanelNotice? {
        let model = self.model
        if model.collectionIssue {
            return PanelNotice(message: "本机采集失败", detail: model.collectionStatusMessage, action: "重试",
                               busy: model.isRefreshing) { model.refresh() }
        }
        guard model.quickUsageScope == .all, hasSyncTarget else { return nil }
        let last = model.lastSync.map { "上次同步 " + relativeAgeLabel($0, now: now) } ?? "尚未同步"
        if model.syncIssue {
            return PanelNotice(message: "同步失败 · " + last, detail: model.syncStatusMessage, action: "重试",
                               busy: model.isSyncing) { model.sync() }
        }
        guard let lastSync = model.lastSync else {
            return PanelNotice(message: "其他设备尚未同步", detail: "「全部」目前只含本机和已导入的数据。", action: "同步",
                               busy: model.isSyncing) { model.sync() }
        }
        // Count three missed intervals using the user's automatic sync schedule.
        let staleAfter = TimeInterval(model.syncIntervalMinutes * 3 * 60)
        if model.autoSync, now.timeIntervalSince(lastSync) > staleAfter {
            return PanelNotice(message: "同步已过期 · " + last, detail: model.syncStatusMessage, action: "同步",
                               busy: model.isSyncing) { model.sync() }
        }
        return nil
    }

    private func noticeRow(_ notice: PanelNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if notice.busy {
                ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                    .accessibilityLabel("正在处理")
            } else {
                Button(notice.action) { notice.perform() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color.orange.opacity(contrast == .increased ? 0.24 : 0.12), in: .rect(cornerRadius: 12))
        .help(notice.detail.isEmpty ? notice.message : notice.detail)
        .accessibilityElement(children: .contain)
    }

    // MARK: Cards

    private func rollingChart(_ bins: [QuickUsageBin]) -> some View {
        let maxTokens = Double(max(1, bins.map(\.metrics.tokens).max() ?? 0))
        return GeometryReader { geometry in
            let width = geometry.size.width
            let slot = width / CGFloat(max(1, bins.count))
            let selectedIndex = bins.firstIndex { $0.id == model.quickSelectedBinID }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(bins) { bin in
                        let selected = bin.id == model.quickSelectedBinID
                        let exact = "\(bin.metrics.tokens.formatted()) Token"
                        let interval = timeSpan(bin.cell, full: true)
                        let barHeight = max(2, CGFloat(Double(bin.metrics.tokens) / maxTokens) * 44)
                        Button {
                            model.selectQuickBin(bin.id)
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selected ? orbitAccent : Color.primary.opacity(0.22))
                                .frame(width: max(0, slot - 2), height: barHeight)
                                .frame(width: slot, height: 44, alignment: .bottom)
                                .frame(height: 62, alignment: .top)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("\(interval) · \(exact)；" + (selected ? "再次点按返回近 24 小时" : "点按查看此时段用量"))
                        .accessibilityLabel(interval)
                        .accessibilityValue(exact)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                // Keep the clock ticks out of the button layout: 24+ narrow
                // bars get equal hit areas even though each label is wider.
                ForEach(rollingTickIndices(count: bins.count, width: width, selected: selectedIndex), id: \.self) { index in
                    let selected = index == selectedIndex
                    Text(clock(bins[index].cell.bounds.lowerBound))
                        .font(.system(size: 9, weight: selected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(selected ? Color.primary : panelSecondary(contrast))
                        .fixedSize()
                        .position(x: rollingTickX(index, width: width, slot: slot), y: 54)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 62)
    }

    private func rollingTickIndices(count: Int, width: CGFloat, selected: Int?) -> [Int] {
        guard count > 0 else { return [] }
        let tickCount = min(count, max(1, Int(width / 52)))
        guard tickCount > 1 else { return [selected ?? 0] }
        let slot = width / CGFloat(count)
        var indices = (0..<tickCount).map { Int((Double($0 * (count - 1)) / Double(tickCount - 1)).rounded()) }
        if let selected, !indices.contains(selected) {
            let x = rollingTickX(selected, width: width, slot: slot)
            indices.removeAll { abs(rollingTickX($0, width: width, slot: slot) - x) < 35 }
            indices.append(selected)
        }
        return indices.sorted()
    }

    private func rollingTickX(_ index: Int, width: CGFloat, slot: CGFloat) -> CGFloat {
        let inset = min(17, width / 2)
        return min(width - inset, max(inset, (CGFloat(index) + 0.5) * slot))
    }

    private func clock(_ date: Date) -> String {
        model.formatDate(date, as: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(Locale(identifier: "zh_CN")))
    }

    private func timeSpan(_ cell: UsageMiniTrendWindow.Cell, full: Bool) -> String {
        let start = cell.bounds.lowerBound
        let end = cell.bounds.upperBound
        let calendar = model.displayCalendar
        let differentDay = !calendar.isDate(start, inSameDayAs: end)
        let differentOffset = calendar.timeZone.secondsFromGMT(for: start) != calendar.timeZone.secondsFromGMT(for: end)
        func label(_ date: Date, includeDate: Bool) -> String {
            let day = includeDate
                ? model.formatDate(date, as: .dateTime.month().day().locale(Locale(identifier: "zh_CN"))) + " "
                : ""
            let offset = differentOffset && full
                ? " " + model.formatDate(date, as: .dateTime.timeZone(.iso8601(.short))) : ""
            return day + clock(date) + offset
        }
        let includeStartDate = full || differentDay || !calendar.isDate(start, inSameDayAs: .now)
        return label(start, includeDate: includeStartDate) + "–" + label(end, includeDate: differentDay)
    }

    @ViewBuilder private var breakdown: some View {
        let rows = model.quickBreakdown
        if let first = rows.first {
            let top = max(1, Double(first.tokens))
            let visibleCount = 5
            if rows.count > visibleCount {
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) {
                        ForEach(rows) { breakdownRow($0, top: top) }
                    }
                }
                .frame(height: CGFloat(visibleCount) * Self.rowHeight + CGFloat(visibleCount - 1) * Self.rowSpacing)
                .id(QuickBreakdownViewID(bin: model.quickSelectedBinID, scope: model.quickUsageScope, dimension: model.quickUsageDimension))
            } else {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(rows) { breakdownRow($0, top: top) }
                }
            }
        } else {
            Text("所选时段暂无用量").font(.system(size: 11)).foregroundStyle(panelSecondary(contrast))
        }
    }

    private static let rowHeight: CGFloat = 22
    private static let rowSpacing: CGFloat = 3

    /// A short meter beside the amount leaves the name column and row edges quiet.
    @ViewBuilder private func breakdownRow(_ row: QuickUsageRow, top: Double) -> some View {
        let amount = "\(row.tokens.formatted()) Token"
        let device = row.deviceID.map { model.deviceNames[$0] ?? $0 }
        let isModel = model.quickUsageDimension == .model
        let name = isModel ? model.modelDisplayName(row.id) : row.label
        let details = [name, isModel && name != row.id ? row.id : nil, row.sessionID, device, amount]
            .compactMap { $0 }.joined(separator: "\n")
        let filtering = isModel && model.quickModelFilter != nil
        let selected = filtering && model.quickModelFilter == row.id
        let dimmed = filtering && !selected
        let content = HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(verbatim: name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(dimmed ? panelSecondary(contrast) : .primary)
                    .lineLimit(1).truncationMode(.middle)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(panelSecondary(contrast))
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 4)
            let meterWidth = 52.0
            Capsule().fill(Color.primary.opacity(0.08)).frame(width: meterWidth, height: 3).overlay(alignment: .leading) {
                if row.tokens > 0 {
                    Capsule().fill(selected ? orbitAccent : Color.primary.opacity(dimmed ? 0.22 : 0.36))
                        .frame(width: min(meterWidth, max(2, meterWidth * Double(row.tokens) / top)))
                }
            }
            .accessibilityHidden(true)
            Text(compactTokenCount(row.tokens)).font(numberFont)
                .foregroundStyle(selected ? Color.primary : panelSecondary(contrast))
                .lineLimit(1).minimumScaleFactor(0.82)
                .frame(width: 49, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
        if isModel {
            Button { model.toggleQuickModel(row.id) } label: { content }
                .buttonStyle(.plain)
                .help(details + (selected ? "\n点按取消筛选" : "\n点按筛选上方用量和趋势"))
                .accessibilityLabel(name)
                .accessibilityValue(amount)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            content.help(details)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(amount)
        }
    }

    private func summaryMetric(_ title: String, value: String, suffix: String? = nil, help: String) -> some View {
        let amount = Text(value).font(headlineFont)
        let unit = Text(suffix ?? "").font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundColor(.secondary)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(panelSecondary(contrast)).lineLimit(1)
            Text("\(amount)\(unit)").lineLimit(1)
                .foregroundStyle(value == "—" ? panelSecondary(contrast) : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String?, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(panelSecondary(contrast))
            Text(value ?? "—").font(numberFont).foregroundStyle(value == nil ? panelSecondary(contrast) : .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    private func tool(_ name: String, _ label: String, help: String? = nil, busy: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if busy { ProgressView().controlSize(.mini).frame(width: 20, height: 20) } else { symbol(name) }
        }
        .buttonStyle(QuickToolButtonStyle())
        .disabled(busy).help(help ?? label).accessibilityLabel(label)
    }

    private func symbol(_ name: String) -> some View {
        // Keep the glyph's contrast independent of the glass backdrop and SF Symbol palette.
        Color.primary.frame(width: 20, height: 20).mask {
            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

private struct QuickToolButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : (contrast == .increased ? 0.62 : 0.42))
            .frame(width: 28, height: 28)
            .contentShape(.circle)
            .background {
                if configuration.isPressed { Circle().fill(.fill.tertiary) }
            }
            .glassEffect(.regular.interactive(isEnabled), in: .circle)
    }
}

private struct QuickBreakdownViewID: Hashable {
    let bin: Date?
    let scope: QuickUsageScope
    let dimension: QuickUsageDimension
}

/// The popup's card: a quiet title row, an optional trailing note and accessory, then content.
struct QuietCard<Content: View, Accessory: View>: View {
    let title: String
    var trailing: String?
    /// A selected model is shown inline so filtering doesn't add another row.
    var filter: String?
    var filterID: String?
    var clearFilter: (() -> Void)?
    private let accessoryBesideTitle: Bool
    private let accessory: Accessory
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(title: String, trailing: String? = nil, filter: String? = nil, filterID: String? = nil,
         clearFilter: (() -> Void)? = nil, accessoryBesideTitle: Bool = false,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.filter = filter
        self.filterID = filterID
        self.clearFilter = clearFilter
        self.accessoryBesideTitle = accessoryBesideTitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text(filter == nil ? title : title + " · ").foregroundStyle(panelSecondary(contrast)).fixedSize()
                    if let filter {
                        Text(verbatim: filter).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                            .help(filterID.flatMap { $0 == filter ? nil : "\(filter)\n\($0)" } ?? filter)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if filter != nil, let clearFilter {
                    Button(action: clearFilter) {
                        Image(systemName: "xmark.circle").font(.system(size: 10, weight: .medium))
                            .frame(width: 20, height: 20).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(panelSecondary(contrast))
                    .help("取消模型筛选（或再次点按该模型）")
                    .accessibilityLabel("取消模型筛选")
                }
                if accessoryBesideTitle { accessory }
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.system(size: 11).monospacedDigit()).foregroundStyle(panelSecondary(contrast)).fixedSize() }
                if !accessoryBesideTitle { accessory }
            }
            .frame(minHeight: 20)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension QuietCard where Accessory == EmptyView {
    init(title: String, trailing: String? = nil, filter: String? = nil, filterID: String? = nil,
         clearFilter: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: trailing, filter: filter, filterID: filterID,
                  clearFilter: clearFilter, accessory: { EmptyView() }, content: content)
    }
}

/// A small neutral 本机 / 全部 switch in place of the accent-tinted segmented control;
/// VoiceOver still sees a picker.
private struct ScopeToggle: View {
    @Binding var selection: QuickUsageScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            ForEach(QuickUsageScope.allCases) { option in
                let on = option == selection
                Button { selection = option } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(on ? Color.primary : panelSecondary(contrast))
                        .padding(.horizontal, 8)
                        .frame(minWidth: 32, minHeight: 20)
                        .background(on ? Color.primary.opacity(contrast == .increased ? 0.22 : 0.12) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1)
        .background(Color.primary.opacity(0.05), in: .capsule)
        .fixedSize()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selection)
        .accessibilityRepresentation {
            Picker("菜单栏和浮窗的用量来源", selection: $selection) {
                ForEach(QuickUsageScope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        }
    }
}
