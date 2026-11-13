// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

/// 请求记录：固定高度的原生表格 + 分页。仅展示元数据，不含提示词、消息或工具内容。
struct MoonRequestHistory: View {
    let model: AppModel
    let requests: [UsageRequest]
    let title: String
    let onOpenRequest: ((UsageRequest) -> Void)?
    /// A chart bucket narrowing the list, shown as a clearable chip beside the count.
    let scopeLabel: String?
    let scopeIcon: String
    let clearScope: (() -> Void)?
    let filterResetID: Int

    @State private var page = 0
    @State private var selection: UsageKey?
    @State private var detail: HistoryRow?
    @State private var query = ""
    @State private var codeFilter = HistoryCodeFilter.all
    @State private var sortOrder = [HistorySort(.time, order: .reverse)]
    @State private var projection: HistoryProjection?
    @FocusState private var tableFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private static let pageSize = 50
    private let tableHeight: CGFloat
    private var inSession: Bool { onOpenRequest != nil }

    init(model: AppModel, requests: [UsageRequest], title: String = "请求记录",
         tableHeight: CGFloat = 365,
         onOpenRequest: ((UsageRequest) -> Void)? = nil,
         scopeLabel: String? = nil, scopeIcon: String = "clock",
         clearScope: (() -> Void)? = nil, filterResetID: Int = 0) {
        self.model = model
        self.requests = requests
        self.title = title
        self.tableHeight = tableHeight
        self.onOpenRequest = onOpenRequest
        self.scopeLabel = scopeLabel
        self.scopeIcon = scopeIcon
        self.clearScope = clearScope
        self.filterResetID = filterResetID
    }

    private var matchingCount: Int { projection?.indices.count ?? requests.count }
    private var pageCount: Int { max(1, (matchingCount + Self.pageSize - 1) / Self.pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var rows: [HistoryRow] {
        let start = currentPage * Self.pageSize
        let end = min(start + Self.pageSize, matchingCount)
        let source = projection?.requests ?? requests
        return (start..<end).map { position in
            let request = source[projection?.indices[position] ?? position]
            return HistoryRow(request: request,
                              deviceName: model.deviceNames[request.deviceID],
                              modelName: request.modelFacetIdentity.map(model.modelDisplayName),
                              cost: model.cost(request))
        }
    }

    private var input: HistoryProjectionInput {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = sortOrder.isEmpty ? [HistorySort(.time, order: .reverse)] : sortOrder
        return .init(requests: requests, query: text, code: codeFilter, order: order,
                     costs: order.contains { $0.field == .cost } ? model.snapshot?.costs ?? [:] : [:],
                     deviceNames: order.contains { $0.field == .device } ? model.deviceNames : [:],
                     namesRevision: (!text.isEmpty || order.contains { $0.field == .model }) ? model.modelNamesDescription : "",
                     scopeLabel: scopeLabel, filterResetID: filterResetID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            filterBar
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("时间", sortUsing: HistorySort(.time)) { row in
                    Button { open(row) } label: {
                        Text(model.formatDate(row.request.timestamp, as: .dateTime.month(.twoDigits).day(.twoDigits)
                            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                            .locale(Locale(identifier: "zh_CN"))))
                            .monospacedDigit().lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(model.formatDate(row.request.timestamp, as: .dateTime.year().month(.wide).day().hour().minute().second()))
                    .accessibilityLabel(model.formatDate(row.request.timestamp, as: .dateTime.year().month(.wide).day().hour().minute().second()))
                    .accessibilityHint("打开请求详情")
                    .moonTableScrollClamp(inSession)
                }
                .width(min: 96, ideal: inSession ? 104 : 124)
                // The session heading already identifies the device and client for these requests.
                if !inSession {
                    TableColumn("设备", sortUsing: HistorySort(.device)) { row in
                        Text(verbatim: row.deviceLabel)
                            .lineLimit(1).truncationMode(.tail)
                            .help(row.deviceLabel)
                    }
                    .width(min: 72, ideal: 128)
                    TableColumn("客户端", sortUsing: HistorySort(.client)) { row in
                        Text(row.request.agentGroup.label).lineLimit(1)
                    }
                    .width(min: 56, ideal: 90)
                }
                TableColumn("模型", sortUsing: HistorySort(.model)) { row in
                    Text(verbatim: row.modelName ?? "—")
                        .lineLimit(1).truncationMode(.tail)
                        .help(row.request.modelFacetIdentity ?? "源日志未记录模型")
                }
                .width(min: 90, ideal: inSession ? 137 : 170)
                TableColumn("请求档位", sortUsing: HistorySort(.tier)) { row in
                    RequestedTierCell(rawValue: row.request.requestedServiceTier)
                }
                .width(min: 72, ideal: inSession ? 76 : 104)
                TableColumn("输出 Token", sortUsing: HistorySort(.output)) { row in
                    RequestTokenCell(output: row.request.outputTokens, reasoning: row.request.reasoningTokens)
                }
                .width(min: 88, ideal: inSession ? 100 : 112)
                .alignment(.leading)
                TableColumn("状态", sortUsing: HistorySort(.status)) { row in
                    StatusBadge(request: row.request)
                }
                .width(min: 55, ideal: inSession ? 58 : 74)
                TableColumn("等效费用", sortUsing: HistorySort(.cost)) { row in
                    let cost = row.cost
                    Text(apiCostLabel(cost)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(cost == nil ? "这次请求未计价" : "按 API 价目估算")
                }
                .width(min: 54, ideal: 70)
                .alignment(.trailing)
                TableColumn("估算 TPS", sortUsing: HistorySort(.tps)) { row in
                    Text(estimatedTPSLabel(for: row.request)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(estimatedTPSHelp(for: row.request))
                }
                .width(min: 56, ideal: 64)
                .alignment(.trailing)
                TableColumn("详情") { row in
                    Button { open(row) } label: {
                        Image(systemName: "info.circle")
                            .frame(width: 24, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .help("查看请求详情")
                    .accessibilityLabel("查看请求详情")
                }
                .width(36)
            }
            .contextMenu(forSelectionType: UsageKey.self) { keys in
                Button("查看请求详情") { open(keys) }.disabled(keys.count != 1)
            } primaryAction: { keys in
                open(keys)
            }
            .onKeyPress(.return) {
                guard let selection, let row = rows.first(where: { $0.id == selection }) else { return .ignored }
                open(row)
                return .handled
            }
            .overlay {
                if matchingCount == 0 {
                    ContentUnavailableView("暂无请求", systemImage: "moon.zzz",
                                           description: Text(requests.isEmpty
                                                ? (scopeLabel == nil ? "所选范围内没有请求记录" : "此时段没有符合筛选的请求")
                                                : "没有符合表内筛选的请求"))
                }
            }
            .frame(height: tableHeight)
            .focused($tableFocused)
            .modifier(SessionTableFocus(enabled: inSession, focused: $tableFocused))
        }
        .task(id: input) { [input] in await rebuild(input) }
        .onChange(of: matchingCount) { page = min(page, pageCount - 1) }
        .onChange(of: currentPage) { selection = nil }
        .onChange(of: scopeLabel) { page = 0; selection = nil; projection = nil }
        .onChange(of: filterResetID) {
            query = ""
            codeFilter = .all
            page = 0
            selection = nil
            projection = nil
        }
        .onChange(of: sortOrder) { page = 0; selection = nil }
        .onChange(of: query) { page = 0; selection = nil }
        .onChange(of: codeFilter) { page = 0; selection = nil }
        // Back from a request: re-enabling would hand focus to the search field otherwise.
        .onChange(of: isEnabled) { _, enabled in
            if enabled && inSession { tableFocused = true }
        }
        .sheet(item: $detail) { row in
            VStack(spacing: 0) {
                HStack {
                    Text("请求详情").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("关闭") { detail = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                MoonRequestDetail(request: row.request, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 560, height: 600)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(matchingCount == requests.count
                 ? "\(matchingCount.formatted()) 条"
                 : "\(matchingCount.formatted()) / \(requests.count.formatted()) 条")
                .foregroundStyle(.secondary).monospacedDigit()
            if let scopeLabel { scopeChip(scopeLabel) }
            Spacer()
            if pageCount > 1 {
                HStack(spacing: 2) {
                    pageButton("chevron.backward.to.line", "第一页", to: 0)
                    pageButton("chevron.backward", "上一页", to: currentPage - 1)
                    Text("\(currentPage + 1) / \(pageCount)").monospacedDigit().frame(minWidth: 56)
                        .accessibilityLabel("第 \(currentPage + 1) 页，共 \(pageCount) 页")
                    pageButton("chevron.forward", "下一页", to: currentPage + 1)
                    pageButton("chevron.forward.to.line", "最后一页", to: pageCount - 1)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索模型、请求 ID、状态或消息", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("在请求表内搜索")
                .frame(maxWidth: 320)
            Menu {
                codeOption(.all)
                codeOption(.unrecorded)
                if let codes = projection?.codes, !codes.isEmpty {
                    Divider()
                    ForEach(codes, id: \.self) { codeOption(.value($0)) }
                }
            } label: {
                Label(codeFilter.label, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.button).buttonStyle(.bordered)
            .fixedSize()
            .accessibilityLabel("按 HTTP 状态码筛选请求")
            .accessibilityValue(codeFilter.label)
            if !query.isEmpty || codeFilter != .all {
                Button("清除表内筛选", systemImage: "xmark.circle") {
                    query = ""
                    codeFilter = .all
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("清除表内筛选")
            }
            Spacer(minLength: 0)
        }
    }

    private func codeOption(_ option: HistoryCodeFilter) -> some View {
        Button { codeFilter = option } label: {
            if option == codeFilter { Label(option.label, systemImage: "checkmark") }
            else { Text(option.label) }
        }
        .accessibilityAddTraits(option == codeFilter ? .isSelected : [])
    }

    @MainActor
    private func rebuild(_ input: HistoryProjectionInput) async {
        var names: [String: String] = [:]
        if !input.query.isEmpty || input.order.contains(where: { $0.field == .model }) {
            for id in Set(input.requests.compactMap(\.modelFacetIdentity)) { names[id] = model.modelDisplayName(id) }
        }
        let modelNames = names
        let worker = Task.detached(priority: .userInitiated) {
            try HistoryProjection.build(input: input, names: modelNames)
        }
        do {
            let next = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            projection = next
        } catch {
            // A newer input replaced this request list or sort order.
        }
    }

    private func scopeChip(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: scopeIcon).imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(label).monospacedDigit().lineLimit(1)
            if let clearScope {
                Button(action: clearScope) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("恢复当前范围内的请求")
                .accessibilityLabel("清除\(label)筛选")
            }
        }
        .font(.callout)
        .padding(.leading, 8).padding(.trailing, clearScope == nil ? 8 : 4).padding(.vertical, 3)
        .background(.fill.tertiary, in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("范围：\(label)")
    }

    private func pageButton(_ symbol: String, _ label: String, to target: Int) -> some View {
        Button { page = target } label: {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .disabled(target < 0 || target >= pageCount || target == currentPage)
        .help(label)
        .accessibilityLabel(label)
    }

    private func open(_ keys: Set<UsageKey>) {
        guard keys.count == 1, let key = keys.first, let row = rows.first(where: { $0.id == key }) else { return }
        open(row)
    }

    private func open(_ row: HistoryRow) {
        selection = row.id
        if let onOpenRequest {
            onOpenRequest(row.request)
        } else {
            detail = row
        }
    }
}

/// A session sheet opens on its request table, so the search field doesn't take focus and its ring.
private struct SessionTableFocus: ViewModifier {
    let enabled: Bool
    let focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if enabled {
            content.defaultFocus(focused, true)
        } else {
            content
        }
    }
}

private struct HistoryRow: Identifiable, Sendable {
    let request: UsageRequest
    let deviceName: String?
    let modelName: String?
    let cost: Double?
    var id: UsageKey { request.key }
    var deviceLabel: String { deviceName ?? request.deviceID }
}

private enum HistoryCodeFilter: Equatable, Sendable {
    case all, unrecorded, value(Int)

    var label: String {
        switch self {
        case .all: "全部 HTTP 状态"
        case .unrecorded: "未记录状态码"
        case let .value(code): "HTTP \(code)"
        }
    }

    func includes(_ code: Int?) -> Bool {
        switch self {
        case .all: true
        case .unrecorded: code == nil
        case let .value(value): code == value
        }
    }
}

private enum HistorySortField: Hashable, Sendable {
    case time, device, client, model, tier, output, status, cost, tps
}

private struct HistorySort: SortComparator, Hashable, Sendable {
    let field: HistorySortField
    var order: SortOrder

    init(_ field: HistorySortField, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    func compare(_ lhs: HistoryRow, _ rhs: HistoryRow) -> ComparisonResult {
        let a = lhs.request, b = rhs.request
        switch field {
        case .time: return directed(compareValue(a.timestamp, b.timestamp))
        case .device: return directed(lhs.deviceLabel.localizedStandardCompare(rhs.deviceLabel))
        case .client: return directed(a.agentGroup.label.localizedStandardCompare(b.agentGroup.label))
        case .model: return compareOptional(lhs.modelName, rhs.modelName) { $0.localizedStandardCompare($1) }
        case .tier:
            return compareOptional(requestedTierLabel(a.requestedServiceTier), requestedTierLabel(b.requestedServiceTier)) {
                $0.localizedStandardCompare($1)
            }
        case .output: return directed(compareValue(a.outputTokens, b.outputTokens))
        case .status:
            if a.observedHTTPStatusCode != nil || b.observedHTTPStatusCode != nil {
                return compareOptional(a.observedHTTPStatusCode, b.observedHTTPStatusCode, compareValue)
            }
            return directed(compareValue(a.statusFacet, b.statusFacet))
        case .cost: return compareOptional(lhs.cost, rhs.cost, compareValue)
        case .tps: return compareOptional(a.estimatedTPS, b.estimatedTPS, compareValue)
        }
    }

    private func compareOptional<T>(_ lhs: T?, _ rhs: T?, _ compare: (T, T) -> ComparisonResult) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (a?, b?): directed(compare(a, b))
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        }
    }

    private func directed(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

private func compareValue<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
}

private struct HistoryProjectionInput: Equatable, Sendable {
    let requests: [UsageRequest]
    let query: String
    let code: HistoryCodeFilter
    let order: [HistorySort]
    let costs: [UsageKey: RequestCost]
    let deviceNames: [String: String]
    let namesRevision: String
    let scopeLabel: String?
    let filterResetID: Int
}

private struct HistoryProjection: Sendable {
    let requests: [UsageRequest]
    let indices: [Int]
    let codes: [Int]

    static func build(input: HistoryProjectionInput, names: [String: String]) throws -> Self {
        let requests = input.requests
        var codes = Set<Int>()
        var indices = [Int]()
        for (index, request) in requests.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            let code = request.observedHTTPStatusCode
            if let code { codes.insert(code) }
            guard input.code.includes(code) else { continue }
            if !input.query.isEmpty {
                let status = RequestStatusPresentation(request)
                let candidates: [String?] = [
                    request.modelFacetIdentity, request.modelFacetIdentity.flatMap { names[$0] },
                    request.id, request.sessionID, request.agentGroup.label, request.cpaKeyLabel,
                    request.status, status.outcome.label, code.map(String.init), status.message,
                ]
                guard candidates.contains(where: { $0?.localizedStandardContains(input.query) ?? false }) else { continue }
            }
            indices.append(index)
        }
        func row(_ index: Int) -> HistoryRow {
            let request = requests[index]
            return .init(request: request, deviceName: input.deviceNames[request.deviceID],
                         modelName: names.isEmpty ? nil : request.modelFacetIdentity.flatMap { names[$0] },
                         cost: input.costs.isEmpty ? nil : input.costs[request.key]?.usd)
        }
        var comparisons = 0
        try indices.sort { lhs, rhs in
            comparisons += 1
            if comparisons.isMultiple(of: 512) { try Task.checkCancellation() }
            let a = row(lhs), b = row(rhs)
            for comparator in input.order {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            if a.request.timestamp != b.request.timestamp { return a.request.timestamp > b.request.timestamp }
            return (a.id.deviceID, a.id.id) < (b.id.deviceID, b.id.id)
        }
        return .init(requests: requests, indices: indices, codes: codes.sorted())
    }
}

private struct RequestTokenCell: View {
    let output: Int64
    let reasoning: Int64?

    var body: some View {
        let outputText = output.formatted()
        let reasoningText = reasoning.flatMap { $0 > 0 ? $0.formatted() : nil }
        let value = reasoningText.map { "\(outputText)，其中推理 \($0)" } ?? outputText
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(outputText)
                .foregroundStyle(.primary)
                .layoutPriority(1)
            if let reasoningText {
                // The same brain mark labels 推理 in the request detail.
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Image(systemName: "brain").imageScale(.small)
                    Text(reasoningText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help("输出 Token：\(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("输出 Token")
        .accessibilityValue(value)
    }
}

private struct RequestedTierCell: View {
    let rawValue: String?

    var body: some View {
        let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requested = ServiceTier(raw)
        let label = requestedTierLabel(rawValue) ?? "—"
        Text(verbatim: label)
            .lineLimit(1)
            .foregroundStyle(requested == .unknown ? .secondary : .primary)
            .help(raw.isEmpty ? "源日志未提供该次请求的档位" : "原始请求档位：\(raw)")
            .accessibilityLabel(raw.isEmpty ? "源日志未提供该次请求的档位" : label)
    }
}

private func requestedTierLabel(_ rawValue: String?) -> String? {
    let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else { return nil }
    let tier = ServiceTier(raw)
    return tier != .unknown || raw.lowercased() == "unknown" ? tier.label : raw
}
