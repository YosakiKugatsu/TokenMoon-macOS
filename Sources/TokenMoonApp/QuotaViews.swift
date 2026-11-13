// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

// MARK: - 主窗口：官方账号额度

struct QuotaDashboardView: View {
    private struct ScrollExtent: Equatable {
        var offset: CGFloat = 0
        var maximum: CGFloat = 0
    }

    let model: AppModel
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollExtent = ScrollExtent()
    @State private var viewport: CGRect = .zero

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        QuotaHeader(model: model, showInsights: { scroller.scrollTo("subscription-insights", anchor: .top) })
                        if model.quotaAccounts.isEmpty {
                            ContentUnavailableView {
                                Label(model.isQuotaRefreshing ? "正在获取额度…" : "暂无官方额度",
                                      systemImage: "gauge.with.dots.needle.33percent")
                            } description: {
                                Text("登录官方账号后点击刷新，即可查看各窗口的剩余额度。")
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                        } else {
                            ForEach(model.quotaAccounts) { account in
                                QuotaAccountCard(model: model, account: account).id("official-quota:" + account.id)
                            }
                        }
                    }
                    .frame(maxWidth: 832, alignment: .leading)
                    Divider().padding(.vertical, 8)
                    SubscriptionInsightsView(model: model, scrollNearEdge: scrollNearEdge) { id in
                        scroller.scrollTo("official-quota:" + id, anchor: .top)
                    }
                    .id("subscription-insights")
                }
                .padding(24)
                .frame(maxWidth: 1320, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scrollPosition)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
            .onScrollGeometryChange(for: ScrollExtent.self) { geometry in
                ScrollExtent(offset: max(0, geometry.visibleRect.minY),
                             maximum: max(0, geometry.contentSize.height - geometry.containerSize.height))
            } action: { _, extent in
                scrollExtent = extent
            }
        }
        .onAppear { model.setSubscriptionUsageVisible(true) }
        .onDisappear { model.setSubscriptionUsageVisible(false) }
    }

    private func scrollNearEdge(_ point: CGPoint) {
        guard viewport.insetBy(dx: 0, dy: -16).contains(point) else { return }
        let edge: CGFloat = 54
        let delta = point.y < viewport.minY + edge ? -18.0 : point.y > viewport.maxY - edge ? 18.0 : 0
        let next = min(scrollExtent.maximum, max(0, scrollExtent.offset + delta))
        if delta != 0, abs(next - scrollExtent.offset) >= 1 { scrollPosition.scrollTo(y: next) }
    }
}

// MARK: - 弹出面板：紧凑额度（不含预测）

/// 卡头的更新时间同时是刷新按钮；圆环点按后才显示重置时间。
struct QuotaMiniPanel: View {
    let model: AppModel
    private let maxAccounts = 4
    private let maxWindows = 3
    @State private var revealed: QuotaMiniSelection?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        QuietCard(title: "官方额度（%）") {
            QuotaRefreshButton(model: model)
        } content: {
            // 陈旧和“待刷新”取决于当前时间，浮窗打开期间每 30 秒重算。
            TimelineView(.periodic(from: .now, by: 30)) { context in
                accounts(now: context.date)
            }
        }
    }

    private var calendar: Calendar {
        var calendar = model.displayCalendar
        calendar.timeZone = model.displayTimeZone
        return calendar
    }

    @ViewBuilder private func accounts(now: Date) -> some View {
        if model.quotaAccounts.isEmpty {
            Text(model.isQuotaRefreshing ? "正在获取额度…" : "暂无已登录的官方账号额度")
                .font(.system(size: 11))
                .foregroundStyle(quotaSecondary(contrast))
        } else {
            let shown = Array(model.quotaAccounts.prefix(maxAccounts))
            let hidden = model.quotaAccounts.count - maxAccounts
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { account in
                    if account.id != shown.first?.id {
                        // 从名称列起始处开始，与图标列留白对齐。
                        Divider().padding(.leading, QuotaMiniLayout.textInset).padding(.vertical, QuotaMiniLayout.rowInset)
                    }
                    QuotaMiniRow(account: account, slots: maxWindows, now: now, calendar: calendar, revealed: $revealed)
                }
                if hidden > 0 {
                    Text("另有 \(hidden) 个账号，请在主窗口查看")
                        .font(.system(size: 10))
                        .foregroundStyle(quotaSecondary(contrast))
                        .padding(.top, 6)
                }
            }
            // 最后一行以卡片底边作为下边界，保留与上方分隔线相同的视觉留白。
            .padding(.bottom, shown.count > 1 && hidden <= 0 ? QuotaMiniLayout.rowInset - QuotaMiniLayout.cardInset : 0)
        }
    }
}

/// “3 分钟前更新 ↻”：读数时间与刷新是同一个控件，刷新中只换图标，文字宽度不跳。
private struct QuotaRefreshButton: View {
    let model: AppModel
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button { model.refreshQuota() } label: {
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(freshness(now: context.date))
                }
                Group {
                    if model.isQuotaRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                }
                .frame(width: 12, height: 12)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(quotaSecondary(contrast))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color.primary.opacity(hovered && !model.isQuotaRefreshing ? 0.08 : 0), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(model.isQuotaRefreshing)
        .help([model.quotaStatusMessage, "刷新官方额度"].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityLabel(model.isQuotaRefreshing ? "正在刷新额度" : "刷新额度")
        .accessibilityValue(freshness(now: .now))
    }

    private func freshness(now: Date) -> String {
        model.quotaLastRefresh.map { updatedAgeLabel($0, now: now) } ?? "尚未读取"
    }
}

// MARK: - 共享组件

private struct QuotaHeader: View {
    let model: AppModel
    let showInsights: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("官方额度（%）").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let last = model.quotaLastRefresh {
                    Text("上次刷新 " + model.formatRelativeDate(last))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("尚未刷新").font(.callout).foregroundStyle(.secondary)
                }
                if !model.quotaStatusMessage.isEmpty {
                    Text(model.quotaStatusMessage)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("用量洞察", systemImage: "arrow.down", action: showInsights)
                .buttonStyle(.bordered)
            Button { model.refreshQuota() } label: {
                if model.isQuotaRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.isQuotaRefreshing)
            .help("刷新官方账号额度")
            .accessibilityLabel(model.isQuotaRefreshing ? "正在刷新额度" : "刷新额度")
        }
    }
}

private struct QuotaAccountCard: View {
    let model: AppModel
    let account: QuotaAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AgentMark(agent: account.agent, size: 26)
                    .frame(width: 40, height: 40)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.displayName).font(.headline).lineLimit(1)
                        Text(account.agent.label).font(.caption).foregroundStyle(.secondary)
                        if let plan = account.planDisplayName {
                            Text(plan)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if account.provenance != .lastKnown || account.agent != .codex, let observedAt = account.observedAt {
                        let observed = model.formatRelativeDate(observedAt)
                        if account.provenance != .live || observed != model.quotaLastRefresh.map(model.formatRelativeDate) {
                            Text("数据更新于 " + observed)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if account.provenance != .live {
                        Label(account.isCachedReading ? "客户端缓存" : "本次未能读取，显示上次有效读数",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let note = account.note, !note.isEmpty {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            let entries = account.displayEntries
            if entries.isEmpty {
                Text("该账号暂无额度窗口数据").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    if let window = entry.window {
                        QuotaWindowRow(model: model, account: account, window: window)
                    } else {
                        QuotaPlaceholderRow(account: account, entry: entry)
                    }
                    if entry.id != entries.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct QuotaWindowRow: View {
    let model: AppModel
    let account: QuotaAccount
    let window: QuotaWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let state = account.freshness(for: window, now: now)
        let pending = state == .resetPending || state == .unavailable
        let lastKnown = account.provenance == .lastKnown && state == .stale
            ? window.observedAt.map { "上次有效读数：" + statusClockLabel($0, now: now, calendar: model.displayCalendar) }
            : nil
        let reset = window.resetDetail(in: model.displayCalendar, now: now)
        // 已过重置时间的旧百分比不再代表当前余量，环只留空轨道。
        return QuotaDashboardWindowLayout(title: window.label, duration: window.uniqueDurationText.map { "周期 " + $0 },
                                          detail: [reset, lastKnown].compactMap { $0 }.joined(separator: " · ")) {
            QuotaRing(remaining: pending ? nil : window.safeRemaining)
                .opacity(state == .cached || state == .stale ? 0.6 : 1)
                .quotaRingInfo(account: account, window: window, calendar: model.displayCalendar, now: now, note: lastKnown)
        } forecast: {
            QuotaForecastBlock(forecast: model.forecast(for: account, window: window), unavailableReason: {
                switch state {
                case .cached: "客户端缓存不参与预测"
                case .stale: "需要新的官方读数"
                case .resetPending: "等待读取新周期"
                case .fresh, .unavailable: nil
                }
            }())
        }
    }
}

private struct QuotaPlaceholderRow: View {
    let account: QuotaAccount
    let entry: QuotaDisplayEntry

    var body: some View {
        QuotaDashboardWindowLayout(title: entry.label, duration: nil, detail: entry.detail) {
            QuotaRing(remaining: entry.displayedRemaining)
                .quotaPlaceholderInfo(account: account, entry: entry)
        } forecast: {
            EmptyView()
        }
    }
}

private struct QuotaDashboardWindowLayout<Ring: View, Forecast: View>: View {
    let title: String
    let duration: String?
    let detail: String
    @ViewBuilder let ring: Ring
    @ViewBuilder let forecast: Forecast

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ring
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let duration {
                    Text(duration).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
            }
            .frame(minWidth: 150, alignment: .leading)
            .help([title, duration, detail].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 12)
            forecast.frame(maxWidth: 320)
        }
        .frame(minHeight: QuotaRing.diameter)
    }
}

private struct QuotaForecastBlock: View {
    let forecast: QuotaForecastDisplay?
    var unavailableReason: String? = nil

    var body: some View {
        let headline = forecast?.headline ?? "暂无预测"
        let detail = forecast?.detail ?? unavailableReason ?? "需同一窗口至少 3 次读数，覆盖 1 小时"
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.callout.weight(.medium))
                    .foregroundStyle(forecast == nil ? .secondary : .primary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true).accessibilityHidden(detail.isEmpty)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 浮窗额度行的固定尺寸。圆环列定宽，名称和邮箱只在左列内截断，不会把数字推走；
/// 各账号的 5 小时、7 天和模型列因此上下对齐。
private enum QuotaMiniLayout {
    static let iconSize: CGFloat = 18
    static let iconSpacing: CGFloat = 8
    /// 名称列起点，账号间分隔线也从这里开始。
    static let textInset: CGFloat = iconSize + iconSpacing
    static let slotWidth: CGFloat = 46
    static let ringDiameter: CGFloat = 34
    static let rowInset: CGFloat = 6
    /// Matches QuietCard's standard padding.
    static let cardInset: CGFloat = 12
    static let ringStroke: CGFloat = 2.5
    static let digitSize: CGFloat = 10
    static let resetDigitSize: CGFloat = 8
}

private struct QuotaMiniSelection: Equatable {
    let accountID: String
    let entryID: String
}

private struct QuotaMiniResetText {
    let date: String
    let time: String

    init(_ reset: Date?, unlimited: Bool, calendar: Calendar) {
        let components = reset.map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) }
        if let components, let month = components.month, let day = components.day,
           let hour = components.hour, let minute = components.minute {
            date = "\(month).\(day)"
            time = String(format: "%02d:%02d", hour, minute)
        } else {
            date = unlimited ? "无需" : "暂无"
            time = "重置"
        }
    }
}

/// 浮窗小环的状态。实时读数按余量着色；缓存或陈旧读数去色但保留数字；
/// 已过重置时间与没有读数都只留轨道，前者用虚线区分。
private enum MiniRingState {
    case reading(Double, live: Bool)
    case resetPending
    case missing
}

/// 一行一个账号；默认只显示圆环。两个 Codex 圆环靠右对齐。
private struct QuotaMiniRow: View {
    let account: QuotaAccount
    /// 前两列优先对齐常见的 5 小时和 7 天窗口。
    let slots: Int
    let now: Date
    let calendar: Calendar
    @Binding var revealed: QuotaMiniSelection?

    @Environment(\.colorSchemeContrast) private var contrast

    private var freshness: QuotaReadingFreshness { account.freshness(now: now) }
    private var isStale: Bool { freshness == .cached || freshness == .stale }

    private var staleNote: String? {
        switch freshness {
        case .cached: "客户端缓存"
        case .stale where account.provenance == .lastKnown && account.agent == .codex: "上次有效读数"
        case .stale: account.observedAt.map { relativeAgeLabel($0, now: now) + "读数" } ?? "上次读数"
        default: nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            identity
                .frame(maxWidth: .infinity, alignment: .leading)
            rings
                .fixedSize()
        }
    }

    private var identity: some View {
        HStack(spacing: QuotaMiniLayout.iconSpacing) {
            AgentMark(agent: account.agent, size: QuotaMiniLayout.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                // 客户端名为主，套餐用次要色紧随其后，不再用粗体和“·”堆在一起。
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(account.agent.label)
                        .font(.system(size: 12, weight: .medium))
                    if let plan = account.planDisplayName {
                        Text(plan)
                            .font(.system(size: 11))
                            .foregroundStyle(quotaSecondary(contrast))
                            .layoutPriority(1)
                    }
                }
                .lineLimit(1)
                HStack(spacing: 3) {
                    if isStale {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 8, weight: .medium))
                            .accessibilityHidden(true)
                    }
                    Text(subtitle)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundStyle(quotaTertiary(contrast))
                .lineLimit(1)
            }
        }
        .help(identityHelp)
        .accessibilityElement(children: .combine)
    }

    private var rings: some View {
        HStack(alignment: .center, spacing: 0) {
            if account.displayEntries.isEmpty {
                Text("暂无窗口数据")
                    .font(.system(size: 10))
                    .foregroundStyle(quotaTertiary(contrast))
                    .frame(width: groupWidth, height: QuotaMiniLayout.ringDiameter)
            } else {
                let entries = arrangedEntries
                let shown = entries.compactMap { $0 }
                if account.agent == .codex && shown.count == 2 {
                    ForEach(shown) { cell($0) }
                } else {
                    ForEach(entries.indices, id: \.self) { index in
                        if let entry = entries[index] {
                            cell(entry)
                        } else {
                            Color.clear.frame(width: QuotaMiniLayout.slotWidth, height: QuotaMiniLayout.ringDiameter)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .frame(width: groupWidth, alignment: .trailing)
    }

    private var groupWidth: CGFloat {
        QuotaMiniLayout.slotWidth * CGFloat(slots)
    }

    private func cell(_ entry: QuotaDisplayEntry) -> some View {
        let state = ringState(entry)
        let key = QuotaMiniSelection(accountID: account.id, entryID: entry.id)
        let showingReset = revealed == key
        let reset = QuotaMiniResetText(entry.window?.resetsAt, unlimited: entry.isUnlimited, calendar: calendar)
        let observed = entry.window.flatMap { window in
            guard account.freshness(for: window, now: now) == .stale else { return nil as String? }
            return window.observedAt.map { "上次有效读数：" + statusClockLabel($0, now: now, calendar: calendar) }
        }
        return Button {
            revealed = showingReset ? nil : key
        } label: {
            QuotaMiniRing(state: state, reset: showingReset ? reset : nil)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("\(account.agent.label)，\(entry.label)额度")
        .accessibilityValue(showingReset ? (entry.isUnlimited && entry.window == nil ? entry.detail : "\(reset.date)，\(reset.time)")
            : [remainingLabel(state), observed].compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint(showingReset ? "点按返回余量" : "点按显示重置时间")
        .help([entry.label, remainingLabel(state), observed].compactMap { $0 }.joined(separator: "\n"))
        .frame(width: QuotaMiniLayout.slotWidth)
    }

    private func remainingLabel(_ state: MiniRingState) -> String {
        switch state {
        case let .reading(value, _): "剩余 \(formatPercent(value))"
        case .resetPending: "待读取新一周期"
        case .missing: "暂无读数"
        }
    }

    private func ringState(_ entry: QuotaDisplayEntry) -> MiniRingState {
        guard let window = entry.window else {
            // Codex Pro 没有独立的 5 小时限额：沿用满环 100% 的既有口径。
            return entry.isUnlimited ? .reading(100, live: !isStale) : .missing
        }
        switch account.freshness(for: window, now: now) {
        case .resetPending: return .resetPending
        case .unavailable: return .missing
        case .cached, .stale: return window.safeRemaining.map { .reading($0, live: false) } ?? .missing
        case .fresh: return window.safeRemaining.map { .reading($0, live: true) } ?? .missing
        }
    }

    private var identityHelp: String {
        let observed = account.provenance == .lastKnown && account.agent == .codex ? nil
            : account.observedAt.map { "官方读取于 " + statusClockLabel($0, now: now, calendar: calendar) }
        return [account.displayName, account.note, staleNote, observed].compactMap { $0 }.joined(separator: "\n")
    }

    private var subtitle: String {
        var parts = [staleNote, account.displayName].compactMap { $0 }
        let extra = account.displayEntries.count - arrangedEntries.compactMap { $0 }.count
        if extra > 0 { parts.append("另 \(extra) 个窗口") }
        return parts.joined(separator: " · ")
    }

    private var arrangedEntries: [QuotaDisplayEntry?] {
        var placed = [QuotaDisplayEntry?](repeating: nil, count: slots)
        var other: [QuotaDisplayEntry] = []
        for entry in account.displayEntries {
            switch entry.label {
            case "5 小时" where placed[0] == nil: placed[0] = entry
            case "7 天" where placed[1] == nil: placed[1] = entry
            case let label where label.localizedCaseInsensitiveContains("Fable") && placed[2] == nil:
                placed[2] = entry
            default: other.append(entry)
            }
        }
        if account.agent == .codex || account.agent == .claudeCode || account.agent == .claudeDesktop {
            return placed
        }
        let free = placed.indices.filter { placed[$0] == nil }
        let order = placed.allSatisfy { $0 == nil } ? free : free.filter { $0 >= 2 } + free.filter { $0 < 2 }
        for (index, entry) in zip(order, other) { placed[index] = entry }
        return placed
    }
}

/// 浮窗小环：默认居中显示余量，点按改为两行重置时间。百分比单位放在卡头。
/// 低于 40% 橙、低于 15% 红；缓存或陈旧读数减淡，低余量仍保留警示数字；
/// 已过重置用虚线轨道，未报告只留实线轨道，都显示“—”。阈值与主窗口一致。
private struct QuotaMiniRing: View {
    let state: MiniRingState
    let reset: QuotaMiniResetText?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var increased: Bool { contrast == .increased }
    private let lineWidth = QuotaMiniLayout.ringStroke

    var body: some View {
        ZStack {
            track
            if case let .reading(value, live) = state {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: value / 100)
                    .stroke(arcColor(value, live: live), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            label
                .lineLimit(1)
                .fixedSize()
                .frame(width: QuotaMiniLayout.ringDiameter, height: QuotaMiniLayout.ringDiameter)
        }
        .frame(width: QuotaMiniLayout.ringDiameter, height: QuotaMiniLayout.ringDiameter)
    }

    @ViewBuilder private var track: some View {
        if case .resetPending = state {
            Circle().strokeBorder(Color.primary.opacity(increased ? 0.55 : 0.28),
                                  style: StrokeStyle(lineWidth: lineWidth, dash: [2, 2.5]))
        } else {
            Circle().strokeBorder(Color.primary.opacity(increased ? 0.3 : 0.1), lineWidth: lineWidth)
        }
    }

    @ViewBuilder private var label: some View {
        if let reset {
            VStack(spacing: 0) {
                Text(verbatim: reset.date)
                Text(verbatim: reset.time)
            }
            .font(.system(size: QuotaMiniLayout.resetDigitSize, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.primary)
        } else if case let .reading(value, live) = state {
            Text(quotaRingDigits(value))
                .font(.system(size: QuotaMiniLayout.digitSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(numberColor(value, live: live))
        } else {
            Text("—")
                .font(.system(size: QuotaMiniLayout.digitSize, weight: .medium, design: .rounded))
                .foregroundStyle(quotaTertiary(contrast))
        }
    }

    private func arcColor(_ value: Double, live: Bool) -> Color {
        guard live else { return Color.primary.opacity(increased ? 0.6 : 0.32) }
        switch value {
        case ..<15: return .red
        case ..<40: return .orange
        default: return Color.green.opacity(increased ? 1 : 0.62)
        }
    }

    private func numberColor(_ value: Double, live: Bool) -> Color {
        if !live { return value < 15 ? quotaLowTint(scheme).opacity(0.85) : quotaTertiary(contrast) }
        switch value {
        case ..<15: return quotaLowTint(scheme)
        case ..<40: return scheme == .dark ? .orange : Color(red: 0.62, green: 0.30, blue: 0.07)
        default: return .primary
        }
    }
}

/// 剩余额度环；remaining 为 nil 时仅显示空轨道，不推测数值。
private struct QuotaRing: View {
    let remaining: Double?
    @Environment(\.colorScheme) private var scheme
    static let diameter: CGFloat = 64
    private let lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().strokeBorder(.quaternary, lineWidth: lineWidth)
            if let remaining {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: remaining / 100)
                    .stroke(quotaTint(remaining), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(remaining.map(quotaRingDigits) ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(remaining.map { $0 < 15 ? quotaLowTint(scheme) : Color.primary } ?? Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Self.diameter, height: Self.diameter)
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }
}

private struct QuotaDisplayEntry: Identifiable {
    let label: String
    let reading: CodexMainAllowance.Reading

    var window: QuotaWindow? {
        if case let .reported(window) = reading { return window }
        return nil
    }

    var id: String { window?.id ?? "presentation:\(label)" }
    var isUnlimited: Bool { reading == .unlimited }
    /// 满环只是没有独立短期限额的显示方式，不是客户端读数。
    var displayedRemaining: Double? { isUnlimited ? 100 : window?.safeRemaining }
    var detail: String {
        isUnlimited ? "无需重置" : "官方客户端暂未返回此窗口的数据。"
    }
    /// Longer wording for the tooltip and VoiceOver.
    var explanation: String {
        isUnlimited ? "无需重置：没有单独的 5 小时限额；7 天额度单独显示。" : detail
    }
}

private extension QuotaAccount {
    var displayEntries: [QuotaDisplayEntry] {
        let entries = windows.map { QuotaDisplayEntry(label: $0.label, reading: .reported($0)) }
        guard let main = codexMainAllowance else { return entries }
        let primary = [
            QuotaDisplayEntry(label: "5 小时", reading: main.fiveHours),
            QuotaDisplayEntry(label: "7 天", reading: main.sevenDays),
        ]
        let primaryIDs = Set(primary.compactMap { $0.window?.id })
        return primary + entries.filter { !primaryIDs.contains($0.id) }
    }
}

// MARK: - 格式化与辅助

private func formatPercent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1))) + "%"
}

private func quotaRingDigits(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
}

private func quotaSecondary(_ contrast: ColorSchemeContrast) -> Color {
    .primary.opacity(contrast == .increased ? 1 : 0.77)
}

/// 浮窗额度的第三层文字（邮箱、重置时间、陈旧数字）；在实底卡片上仍不低于 4.5:1。
private func quotaTertiary(_ contrast: ColorSchemeContrast) -> Color {
    .primary.opacity(contrast == .increased ? 0.88 : 0.6)
}

private func quotaTint(_ remaining: Double) -> Color {
    switch remaining {
    case ..<15: .red
    case ..<40: .orange
    default: .green
    }
}

private func quotaLowTint(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? .red : Color(red: 0.66, green: 0.12, blue: 0.20)
}

private extension QuotaWindow {
    var safeRemaining: Double? {
        remainingPercent.isFinite ? min(max(remainingPercent, 0), 100) : nil
    }

    var remainingText: String { safeRemaining.map(formatPercent) ?? "—" }

    /// 读数之后窗口已重置：百分比属于上一个周期，等待下一次读取。
    func isExpired(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    var durationText: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return Duration.seconds(durationSeconds)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2)
                .locale(Locale(identifier: "zh_Hans_CN")))
    }

    /// The window length, unless the title already says it ("5 小时", "7 天 · Fable").
    var uniqueDurationText: String? {
        guard let text = durationText, let seconds = durationSeconds else { return nil }
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let title = compact(label)
        let hours = seconds / 3600, days = seconds / 86400
        let spellings = [compact(text),
                         hours == hours.rounded() ? "\(Int(hours))小时" : nil,
                         days == days.rounded() ? "\(Int(days))天" : nil].compactMap { $0 }
        return spellings.contains { title.contains($0) } ? nil : text
    }

    func resetRelative(in calendar: Calendar, now: Date) -> String {
        guard let resetsAt else { return "重置时间未知" }
        if isExpired(at: now) { return "已过重置时间，读数待刷新" }
        return relativeReset(resetsAt, calendar: calendar) + "重置"
    }

    func resetDetail(in calendar: Calendar, now: Date) -> String {
        guard let resetsAt else { return "重置时间未知" }
        let absolute = UsageDisplayTime.format(resetsAt, as: .dateTime.month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_Hans_CN")),
                                               calendar: calendar)
        if isExpired(at: now) { return "已于 \(absolute) 重置，读数待刷新" }
        return "重置于 \(absolute)（\(relativeReset(resetsAt, calendar: calendar))）"
    }

    private func relativeReset(_ resetsAt: Date, calendar: Calendar) -> String {
        var style = Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "zh_Hans_CN"))
        style.calendar = calendar
        return style.format(resetsAt)
    }
}

private extension View {
    func quotaPlaceholderInfo(account: QuotaAccount, entry: QuotaDisplayEntry) -> some View {
        let label = "\(entry.label)额度"
        let value = entry.explanation
        return self
            .help("\(account.displayName) · \(label)\n\(value)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.displayName)，\(label)")
            .accessibilityValue(value)
    }

    /// note 用于陈旧或待刷新的说明，同时进入悬停提示和 VoiceOver。
    func quotaRingInfo(account: QuotaAccount, window: QuotaWindow, calendar: Calendar,
                       now: Date, note: String? = nil) -> some View {
        let state = account.freshness(for: window, now: now)
        let remaining = state == .resetPending ? "待读取新一周期" : window.safeRemaining.map { "剩余 \(formatPercent($0))" } ?? "剩余额度未知"
        let help = ["\(account.displayName) · \(window.label)", remaining, window.resetDetail(in: calendar, now: now), note]
            .compactMap { $0 }.joined(separator: "\n")
        return self
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.displayName)，\(window.label)额度")
            .accessibilityValue(["\(remaining)，\(window.resetRelative(in: calendar, now: now))", note].compactMap { $0 }.joined(separator: "，"))
    }
}
