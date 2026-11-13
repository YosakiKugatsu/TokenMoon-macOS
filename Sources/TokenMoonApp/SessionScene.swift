// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

struct TokenMoonSessionsView: View {
    let model: AppModel
    @State private var selectedSessionID: UsageSession.ID?
    @State private var openedSession: UsageSession?
    @State private var sortOrder = [KeyPathComparator(\UsageSession.startedAt, order: .reverse)]

    private var sessions: [UsageSession] { model.sessions.sorted(using: sortOrder) }
    private var selectedSession: UsageSession? { model.sessions.first { $0.id == selectedSessionID } }

    var body: some View {
        VStack(spacing: 0) {
            summary
            if model.sessions.isEmpty {
                ContentUnavailableView("暂无会话", systemImage: "moon.zzz",
                                       description: Text("调整筛选条件，或等待 TokenMoon 采集本机用量。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionTable
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $openedSession) { session in
            MoonSessionSheet(session: session, model: model)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(model.sessions.count.formatted()) 个会话").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\(SessionFormat.compact(model.metrics.tokens)) Token")
                .font(.callout).foregroundStyle(.secondary)
            let cost = "等效费用 \(apiCostLabel(model.metrics.cost))"
            let unpriced = model.metrics.unpricedRequests
            let coverage = unpriced > 0 ? "\(unpriced.formatted()) 次请求未计价" : "按 API 价目计算"
            Text(cost + (unpriced > 0 && model.metrics.cost != nil ? " · 部分未计价" : ""))
                .font(.callout).foregroundStyle(.secondary)
                .help(coverage)
                .accessibilityLabel(cost)
                .accessibilityHint(coverage)
            Button("查看会话", systemImage: "arrow.up.right.square") {
                openedSession = selectedSession
            }
            .disabled(selectedSession == nil)
            .help("查看选中会话的请求")
        }
        .monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var sessionTable: some View {
        Table(sessions, selection: $selectedSessionID, sortOrder: $sortOrder) {
            TableColumn("会话") { s in
                let title = model.sessionTitle(for: s.id)
                let name = title ?? "会话 · \(s.sessionID.suffix(10))"
                let device = model.deviceNames[s.deviceID] ?? s.deviceID
                Button {
                    selectedSessionID = s.id
                    openedSession = s
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                AgentMark(agent: s.agent, size: 14)
                                Text(s.agent.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            }
                            .fixedSize()
                            Text(verbatim: name).lineLimit(1).truncationMode(.tail)
                        }
                        Text(device)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(title.map { "\($0)\n\(s.sessionID)" } ?? s.sessionID)
                .accessibilityLabel("\(s.agent.label)，\(name)，\(device)")
                .accessibilityHint("打开会话详情")
                .moonTableScrollClamp()
            }
            .width(min: 240, ideal: 320)
            TableColumn("时间", value: \.startedAt) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.formatDate(s.startedAt, as: .dateTime.month().day().hour().minute()))
                    Text(SessionFormat.span(s.endedAt.timeIntervalSince(s.startedAt)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Token", value: \.metrics.tokens) { s in Text(SessionFormat.compact(s.metrics.tokens)).monospacedDigit() }
                .width(min: 64, ideal: 80).alignment(.trailing)
            TableColumn("请求", value: \.metrics.requests) { s in Text(s.metrics.requests, format: .number).monospacedDigit() }
                .width(min: 44, ideal: 56).alignment(.trailing)
            TableColumn("等效费用") { s in
                Text(apiCostLabel(s.metrics.cost)).monospacedDigit()
                    .help(s.metrics.unpricedRequests > 0
                          ? "\(s.metrics.unpricedRequests.formatted()) 次请求未计价，不计入等效费用"
                          : "按 API 价目估算")
            }
                .width(min: 70, ideal: 88).alignment(.trailing)
            TableColumn("缓存") { s in Text(SessionFormat.percent(s.metrics.cacheRate)).monospacedDigit() }
                .width(min: 48, ideal: 60).alignment(.trailing)
            TableColumn("估算 TPS") { s in
                Text(estimatedTPSLabel(for: s.metrics)).monospacedDigit()
                    .help(estimatedTPSHelp(for: s.metrics))
            }
            .width(min: 56, ideal: 68).alignment(.trailing)
        }
        .contextMenu(forSelectionType: UsageSession.ID.self) { ids in
            Button("查看会话") { openedSession = model.sessions.first { $0.id == ids.first } }
                .disabled(ids.count != 1)
        } primaryAction: { ids in
            openedSession = model.sessions.first { $0.id == ids.first }
        }
        .onKeyPress(.return) {
            guard let selectedSession else { return .ignored }
            openedSession = selectedSession
            return .handled
        }
    }
}

private struct MoonSessionSheet: View {
    let session: UsageSession
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var openedRequest: UsageRequest?
    @AccessibilityFocusState private var backFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        AgentMark(agent: session.agent, size: 16)
                        Text(session.agent.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(verbatim: model.sessionTitle(for: session.id) ?? "会话详情")
                        .font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    Text(session.sessionID).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
                    Text(model.deviceNames[session.deviceID] ?? session.deviceID)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if openedRequest == nil {
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("关闭") { dismiss() }
                }
            }
            // The charts and the table read one slice, so they always describe the same requests.
            let requests = model.requests(for: session)
            VStack(alignment: .leading, spacing: 14) {
                SessionDetailCharts(model: model, requests: requests)
                MoonRequestHistory(model: model, requests: requests, title: "会话请求",
                                   tableHeight: Self.tableHeight, onOpenRequest: { openedRequest = $0 })
            }
            // Keep everything mounted so returning preserves the table's page, selection and scroll position.
            .opacity(openedRequest == nil ? 1 : 0)
            .disabled(openedRequest != nil)
            .allowsHitTesting(openedRequest == nil)
            .accessibilityHidden(openedRequest != nil)
            .overlay {
                if let openedRequest {
                    requestPane(openedRequest)
                }
            }
        }
        .padding(22)
        .frame(width: 850)
    }

    /// The charts sit above the list, so the table gives up height on shorter screens
    /// instead of the sheet growing past them or nesting another scroll view.
    private static var tableHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return min(340, max(200, visible - 520))
    }

    private func requestPane(_ request: UsageRequest) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("返回会话", systemImage: "chevron.backward") { openedRequest = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityFocused($backFocused)
                Text("请求详情").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)
            Divider()
            MoonRequestDetail(request: request, model: model)
        }
        .onAppear { backFocused = true }
    }
}

struct MoonRequestDetail: View {
    let request: UsageRequest
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    StatusBadge(request: request, includeOutcomeForCode: true).font(.caption)
                    Text(verbatim: routeTitle)
                        .font(.title3.weight(.semibold)).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                        .help(rawRoute)
                    Text(model.formatDate(request.timestamp, as: .dateTime.year().month().day().hour().minute().second()))
                        .font(.callout).foregroundStyle(.secondary)
                }
                responseMetadata
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    tile("合计", SessionFormat.full(request.totalTokens), "sum", accent: true)
                    tile("输入", SessionFormat.full(request.inputTokens), "arrow.down.to.line")
                    tile("输出", SessionFormat.full(request.outputTokens), "arrow.up.to.line")
                    tile("缓存读取", SessionFormat.full(request.cacheReadTokens), "tray.and.arrow.up")
                    tile("缓存写入", SessionFormat.full(request.cacheWriteTokens), "tray.and.arrow.down")
                    tile("推理", request.reasoningTokens.map(SessionFormat.full) ?? "—", "brain")
                    if let count = request.cacheWrite5mTokens { tile("5 分钟缓存写入", SessionFormat.full(count), "clock") }
                    if let count = request.cacheWrite1hTokens { tile("1 小时缓存写入", SessionFormat.full(count), "clock") }
                    tile("缓存率", SessionFormat.percent(request.cacheRate), "bolt.horizontal")
                    tile("估算 TPS",
                         estimatedTPSLabel(for: request), "gauge.with.dots.needle.33percent")
                        .help(estimatedTPSHelp(for: request))
                    if request.agent != .cpa || request.hasCompleteTiming {
                        tile("完整耗时", SessionFormat.ms(request.hasCompleteTiming ? request.durationMS : nil), "timer")
                    }
                    if request.agent == .cpa, let ttft = request.ttftMS, ttft.isFinite, ttft > 0 {
                        tile("首 Token 耗时", SessionFormat.ms(ttft), "timer.circle")
                    }
                    if !request.hasCompleteTiming, let ms = request.estimatedDurationMS {
                        tile("日志估算耗时", "≈ " + SessionFormat.ms(ms), "clock.arrow.circlepath")
                    }
                    let cost = model.requestCost(request)
                    tile("等效费用", apiCostLabel(cost.usd), "dollarsign.circle")
                        .help(cost.usesCacheWriteFallback ? "1 小时缓存写入使用通用费率估算"
                              : cost.usd == nil ? "这次请求未计价" : "按 API 价目估算")
                }
                meta("模型与路由", "point.3.connected.trianglepath.dotted", [
                    ("请求模型", request.modelFacetIdentity == nil ? nil : model.modelDisplayName(request.requestedModel)),
                    ("发送模型", request.modelFacetIdentity == nil ? nil : request.sentModel.map(model.modelDisplayName)),
                    ("提供商", request.provider), ("提供商 ID", request.providerID),
                    ("推理强度", request.reasoningEffort),
                    ("请求档位", SessionFormat.tier(request.requestedServiceTier))] + cpaRouteMetadata)
                DisclosureGroup("原始模型 ID") {
                    metadataGrid([("请求模型 ID", request.modelFacetIdentity == nil ? nil : request.requestedModel),
                                  ("发送模型 ID", request.modelFacetIdentity == nil ? nil : request.sentModel)])
                        .padding(.top, 6)
                }
                .font(.callout)
                meta("来源与账户", "person.crop.circle", [
                    ("智能体", request.agentGroup.label), ("设备", model.deviceNames[request.deviceID] ?? request.deviceID),
                    (request.accountEvidence == .userConfirmed ? "账号（手动确认）" :
                     request.account == nil && request.sessionCreatorAccountEmail != nil ? "账号（会话创建）" : "账号",
                     request.account ?? request.sessionCreatorAccountEmail ?? "未记录"),
                    ("会话创建账号 ID", request.sessionCreatorAccountID),
                    ("登录方式", loginMethodLabel),
                    ("渠道", request.channelIdentity), ("来源", request.source)]
                    + cpaSourceMetadata + [
                    ("计时来源", request.hasCompleteTiming ? request.timingSource : request.estimatedTimingSource),
                    ("会话标题", model.sessionTitle(for: request.sessionKey)),
                    ("会话 ID", request.sessionID), ("请求 ID", request.id)])
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var responseMetadata: some View {
        let status = RequestStatusPresentation(request)
        return VStack(alignment: .leading, spacing: 8) {
            Label("状态与消息", systemImage: request.isFailure ? "xmark.circle" : "info.circle")
                .font(.headline).accessibilityAddTraits(.isHeader)
            metadataGrid([
                ("HTTP 状态码", status.code.map(String.init) ?? "源日志未记录"),
                ("原始状态", request.status),
            ])
            Text("消息").font(.callout).foregroundStyle(.secondary)
            if let message = status.message {
                Text(verbatim: message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("源日志未记录").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var routeTitle: String {
        guard let modelIdentity = request.modelFacetIdentity else { return "—" }
        if request.isFailure { return model.modelDisplayName(modelIdentity) }
        let requested = model.modelDisplayName(request.requestedModel)
        guard let sent = request.sentModel else { return requested }
        let name = model.modelDisplayName(sent)
        return name == requested ? requested : "\(requested) → \(name)"
    }

    private var cpaRouteMetadata: [(String, String?)] {
        guard request.agent == .cpa else { return [] }
        var rows: [(String, String?)] = []
        if let sent = request.sentServiceTier { rows.append(("发送档位", SessionFormat.tier(sent))) }
        if request.actualServiceTierEvidence == .conflicting {
            rows.append(("实际档位", "未确认"))
        } else if let served = request.serviceTier {
            rows.append(("实际档位", SessionFormat.tier(served)))
        }
        return rows
    }

    private var cpaSourceMetadata: [(String, String?)] {
        guard request.agent == .cpa else { return [] }
        var rows: [(String, String?)] = []
        if let key = request.cpaKeyLabel ?? request.cpaKeyID { rows.append(("CPA Key", key)) }
        let basis = request.hasCompleteTiming ? "完整请求" : request.estimatedDurationMS != nil ? "日志估算" : "未记录"
        rows.append(("计时口径", basis))
        return rows
    }

    private var loginMethodLabel: String {
        if request.loginMethodEvidence == .conflicting { return "未确认" }
        guard let method = request.loginMethod else { return "未记录" }
        return switch method.lowercased().filter(\.isLetter) {
        case "chatgpt", "chatgptauthtokens", "chatgpttokens": "ChatGPT 登录"
        case "apikey": "API Key"
        case "oauth": "OAuth"
        case "sso": "SSO"
        default: method
        }
    }

    private var rawRoute: String {
        guard let modelIdentity = request.modelFacetIdentity else { return "源日志未记录模型" }
        if request.isFailure { return modelIdentity }
        guard let sent = request.sentModel, sent != request.requestedModel else { return request.requestedModel }
        return "\(request.requestedModel) → \(sent)"
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).frame(width: 14)
                Text(title).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .help(title + "：" + value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func meta(_ title: String, _ symbol: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).accessibilityAddTraits(.isHeader)
            metadataGrid(rows)
        }
    }

    private func metadataGrid(_ rows: [(String, String?)]) -> some View {
        let items = rows.map { (label: $0.0, value: $0.1 ?? "—") }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(items, id: \.label) { item in
                GridRow {
                    Text(item.label).foregroundStyle(.secondary)
                    Text(verbatim: item.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

struct RequestStatusPresentation {
    enum Outcome: Int {
        case success, failure, unknown

        var label: String {
            switch self {
            case .success: "成功"
            case .failure: "失败"
            case .unknown: "未知"
            }
        }
        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failure: "xmark.circle.fill"
            case .unknown: "circle.dotted"
            }
        }
        var tint: Color {
            switch self {
            case .success: .green
            case .failure: .red
            case .unknown: .secondary
            }
        }
    }

    let code: Int?
    let outcome: Outcome
    let message: String?

    init(_ request: UsageRequest) {
        code = request.observedHTTPStatusCode
        switch request.statusFacet {
        case .succeeded: outcome = .success
        case .failed: outcome = .failure
        case .unknown, .http: outcome = .unknown
        }
        let safeText = request.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        message = safeText.isEmpty ? nil : String(safeText.prefix(1_024))
    }

    var description: String {
        guard let code else { return outcome.label }
        return outcome == .unknown ? "HTTP \(code)" : "\(outcome.label) · HTTP \(code)"
    }
}

struct StatusBadge: View {
    let request: UsageRequest
    var includeOutcomeForCode = false

    var body: some View {
        let status = RequestStatusPresentation(request)
        let label = includeOutcomeForCode ? status.description : status.code.map(String.init) ?? status.outcome.label
        HStack(spacing: 4) {
            Image(systemName: status.outcome.symbol)
                .foregroundStyle(status.outcome.tint)
                .accessibilityHidden(true)
            Text(label).monospacedDigit().lineLimit(1)
        }
        .accessibilityLabel(status.description)
        .help([status.description, status.message].compactMap { $0 }.joined(separator: "\n"))
    }
}

private enum SessionFormat {
    static func compact(_ v: Int64) -> String { compactTokenCount(v) }
    static func full(_ v: Int64) -> String { v.formatted(IntegerFormatStyle<Int64>()) }
    static func percent(_ v: Double?) -> String { v.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "—" }
    static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 1000 ? "\(Int(v.rounded())) ms" : (v / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }
    static func span(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
    static func tier(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "源日志未记录" }
        let tier = ServiceTier(raw)
        guard tier != .unknown else { return raw == "auto" ? "自动 (auto)" : raw }
        return "\(tier.label) (\(raw))"
    }
}
