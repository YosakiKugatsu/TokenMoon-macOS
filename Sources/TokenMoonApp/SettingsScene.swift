// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import TokenMoonCore

enum SettingsPane: String, CaseIterable {
    case appearance, sources, pricing, sync

    var title: String {
        switch self {
        case .appearance: "外观"
        case .sources: "数据源"
        case .pricing: "定价"
        case .sync: "同步"
        }
    }
}

struct TokenMoonSettingsView: View {
    @Bindable var model: AppModel
    var pane: SettingsPane = .appearance

    @ViewBuilder
    var body: some View {
        switch pane {
        case .appearance: appearanceTab
        case .sources: sourcesTab
        case .pricing: pricingTab
        case .sync: webDAVTab
        }
    }

    private var appearanceTab: some View {
        Form {
            LoginStartSettingsSection()
            Section("菜单栏") {
                Toggle("在菜单栏显示 TokenMoon", isOn: $model.showsMenuBarItem)
                Picker("显示内容", selection: $model.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!model.showsMenuBarItem)
                if model.menuBarDisplayMode == .quota {
                    Picker("额度来源", selection: $model.menuBarQuotaSource) {
                        ForEach(MenuBarQuotaSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .disabled(!model.showsMenuBarItem)
                } else if model.menuBarDisplayMode == .usage {
                    metricPicker("左侧指标", selection: $model.menuBarPrimaryMetric)
                    metricPicker("右侧指标", selection: $model.menuBarSecondaryMetric)
                    Toggle("显示近 24 小时趋势", isOn: $model.showsMenuTrend)
                        .disabled(!model.showsMenuBarItem)
                }
            }
            Section("时间") {
                DisplayTimeZoneSetting(selection: $model.displayTimeZoneID)
            }
            Section {
                Toggle("自动纵轴", isOn: $model.automaticRateYAxis)
            } header: {
                Text("图表")
            } footer: {
                Text("按可见数据缩放缓存命中率和估算 TPS。关闭后从 0 起，缓存命中率固定显示 0–100%。")
            }
            Section {
                Picker("用量排行分组", selection: $model.quickUsageDimension) {
                    ForEach(QuickUsageDimension.allCases) { dimension in
                        Text(dimension.label).tag(dimension)
                    }
                }
            } header: { Text("用量浮窗") }
        }
        .formStyle(.grouped)
    }

    /// Each slot shows the last 24 hours, like the rest of the numeric readout.
    private func metricPicker(_ title: String, selection: Binding<MenuBarUsageMetric>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MenuBarUsageMetric.allCases, id: \.self) { metric in
                Text(metric.label).tag(metric)
            }
        }
        .disabled(!model.showsMenuBarItem)
        .help("菜单栏\(title)，统计近 24 小时")
    }

    // MARK: - 数据源

    private var sourcesTab: some View {
        Form {
            ForEach(Agent.localCollectors) { agent in
                Section(agent.label) {
                    logLocation(for: agent)
                    if let report = model.reports.first(where: { $0.agent.id == agent.id }) {
                        LabeledContent("已读取") {
                            Text("\(report.files.formatted()) 个文件 · \(report.requests.formatted()) 次请求")
                                .monospacedDigit()
                        }
                        .help(report.note)
                    } else {
                        LabeledContent("已读取", value: "尚未扫描")
                    }
                }
            }
            Section {
                LabeledContent("备份与迁移") {
                    HStack(spacing: 8) {
                        Button("导入…") { model.importUsage() }.disabled(model.isImporting).help("从文件导入用量记录")
                        Button("导出…") { model.exportUsage() }.help("将用量记录导出为文件")
                    }
                }
                LabeledContent("本机记录") {
                    Button("重新扫描") { model.refresh() }
                        .disabled(model.isRefreshing)
                        .help("重新读取上述来源的用量记录")
                }
                LabeledContent("上次采集") { lastTime(model.lastCollection, never: "尚未采集") }
                LabeledContent("状态") {
                    status(model.collectionStatusMessage, issue: model.collectionIssue,
                           busy: model.isRefreshing || model.isImporting)
                }
            } header: { Text("用量数据") }
        }
        .formStyle(.grouped)
    }

    private func logLocation(for agent: Agent) -> some View {
        let configured = model.rootsDescription(for: agent)
        let paths = configured == "自动查找" ? (UsageCollectors.defaultRoots()[agent] ?? []).map {
            ($0.path as NSString).abbreviatingWithTildeInPath
        } : []
        let summary: String
        let help: String
        if configured.isEmpty {
            summary = "未指定路径 · 自动查找已关闭"
            help = "选择日志文件或目录，或恢复默认以启用自动查找。"
        } else if let first = paths.first {
            summary = "自动查找 · " + first + (paths.count > 1 ? " 等 \(paths.count) 处" : "")
            help = "自动查找以下位置：\n" + paths.joined(separator: "\n")
        } else {
            summary = configured
            help = configured
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("日志位置")
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(help)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("恢复默认") { model.resetRoot(for: agent) }
                    .help("恢复 \(agent.label) 的自动查找")
                Button("选择…") { model.chooseRoot(for: agent) }
                    .help("指定 \(agent.label) 的日志文件或目录")
            }
            .fixedSize()
        }
    }

    // MARK: - 等效定价

    private var pricingTab: some View {
        Form {
            Section {
                Picker("价格来源", selection: $model.priceSource) {
                    ForEach(PriceSource.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("导入…") { model.importPrices() }.help("从本地文件导入价格表")
                        if model.priceSource == .publicCatalog {
                            Button("更新") { model.updatePrices() }.help("获取公开目录的最新价格")
                        }
                    }
                } label: {
                    Text("当前价格表")
                    Text(model.priceDescription)
                }
            } header: { Text("价格来源") } footer: {
                footnote("等效费用按所选 API 价目估算。切换价目会重新计算所有历史。")
            }
            Section {
                LabeledContent {
                    Button(model.isRefreshingModelNames ? "正在更新…" : "更新名称") { model.refreshModelNames() }
                        .disabled(model.isRefreshingModelNames)
                        .help("获取最新的模型显示名称")
                } label: {
                    Text("名称目录")
                    Text(model.modelNamesDescription)
                }
            } header: { Text("模型显示名称") } footer: {
                footnote("更新显示名称不会改变请求记录中的模型 ID 或计价。")
            }
            Section {
                MultiplierField("Fast 倍率", help: "Fast 模式请求相对标准价格的倍数", value: $model.fastMultiplier)
                MultiplierField("UltraFast 倍率", help: "UltraFast 模式请求相对标准价格的倍数", value: $model.ultraFastMultiplier)
                DisclosureGroup("按渠道设置 Fast") {
                    ForEach(["GPT / Codex", "Claude", "Gemini", "Other"], id: \.self) { channel in
                        channelFastOverride(channel)
                    }
                }
            } header: { Text("速度倍率") } footer: {
                footnote("未单独设置的渠道使用全局 Fast 倍率。取值需大于 0 且不超过 100，输入有效数值后自动保存。")
            }
            Section {
                LabeledContent("状态") {
                    status(model.pricingStatusMessage, issue: model.pricingIssue, busy: model.isRefreshingModelNames)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - WebDAV

    private var webDAVTab: some View {
        Form {
            Section {
                syncField("服务器地址") {
                    TextField("服务器地址", text: $model.webDAVURL,
                              prompt: Text(verbatim: "https://dav.example.com/tokenmoon/").foregroundColor(.secondary))
                        .autocorrectionDisabled()
                }
                syncField("用户名") {
                    TextField("用户名", text: $model.webDAVUsername,
                              prompt: Text("输入 WebDAV 用户名").foregroundColor(.secondary))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                }
                syncField("密码") {
                    SecureField("密码", text: $model.webDAVPassword,
                                prompt: Text("输入 WebDAV 密码").foregroundColor(.secondary))
                        .textContentType(.password)
                }
            } header: { Text("服务器") } footer: {
                footnote("填写已有的 HTTPS WebDAV 目录。若服务器允许匿名访问，用户名和密码可留空。密码在同步时保存到本机钥匙串。")
            }
            Section {
                syncField("设备名称") {
                    TextField("设备名称", text: $model.deviceName, prompt: Text("例如：书房 MacBook Pro"))
                }
                LabeledContent("设备 ID") {
                    Text(model.thisDeviceID).font(.callout.monospaced()).textSelection(.enabled)
                }
            } header: { Text("本机") }
            Section {
                Toggle("自动同步", isOn: $model.autoSync)
                SyncIntervalField(minutes: $model.syncIntervalMinutes)
                LabeledContent("上次同步") { lastTime(model.lastSync, never: "尚未同步") }
                LabeledContent("手动同步") {
                    Button { model.sync() } label: {
                        Text(model.isSyncing ? "正在同步…" : "立即同步")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSyncing || trimmedURL.isEmpty)
                    .help("立即下载其他设备的记录并上传本机的记录")
                }
                LabeledContent("状态") {
                    status(model.syncStatusMessage, issue: model.syncIssue, busy: model.isSyncing, empty: syncIdleStatus)
                }
            } header: { Text("同步") } footer: {
                footnote("每次同步会下载其他设备的记录并上传本机记录。自动同步的间隔可设为 1–1440 分钟，默认 5 分钟。")
            }
        }
        .formStyle(.grouped)
    }

    private func syncField<Field: View>(_ title: LocalizedStringKey, @ViewBuilder field: () -> Field) -> some View {
        LabeledContent(title) {
            field()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 330)
        }
    }

    private var syncIdleStatus: String {
        if model.isSyncing { return "正在同步…" }
        if trimmedURL.isEmpty { return "尚未配置 WebDAV" }
        if model.lastSync != nil { return "上次同步成功" }
        let hasUser = !model.webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasUser && model.webDAVPassword.isEmpty { return "尚未验证连接 · 未填写用户名和密码" }
        if !hasUser { return "尚未验证连接 · 未填写用户名" }
        if model.webDAVPassword.isEmpty { return "尚未验证连接 · 未填写密码" }
        return "尚未验证连接"
    }

    // MARK: - 共用

    private var trimmedURL: String { model.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Each pane reports only its own work. A failure stays red until the same kind of
    /// operation succeeds, so background collection can't hide a sync or price error.
    private func status(_ message: String, issue: Bool, busy: Bool, empty: String = "就绪") -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.small).accessibilityLabel("正在处理")
            } else if issue {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .accessibilityLabel("出错")
            }
            Text(verbatim: message.isEmpty ? empty : message)
                .foregroundStyle(issue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func lastTime(_ date: Date?, never: String) -> some View {
        if let date {
            Text(model.formatRelativeDate(date))
                .help(model.formatDate(date, as: .dateTime.year().month(.wide).day().hour().minute().second()))
        } else {
            Text(never)
        }
    }

    @ViewBuilder private func channelFastOverride(_ channel: String) -> some View {
        Toggle("单独设置 \(channel)", isOn: Binding {
            model.fastMultipliersByChannel[channel] != nil
        } set: { enabled in
            model.setFastMultiplier(enabled ? model.fastMultiplier : nil, channel: channel)
        })
        if model.fastMultipliersByChannel[channel] != nil {
            MultiplierField("\(channel) 的 Fast 倍率", help: "仅应用于此渠道的 Fast 请求", value: Binding {
                model.fastMultipliersByChannel[channel] ?? model.fastMultiplier
            } set: { model.setFastMultiplier($0, channel: channel) })
        }
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

private struct LoginStartSettingsSection: View {
    @State private var controller = LoginStartController()

    var body: some View {
        Section("通用") {
            Toggle("登录时启动 TokenMoon", isOn: Binding {
                controller.isEnabled || controller.needsApproval
            } set: { enabled in
                controller.setEnabled(enabled)
            })
            if controller.needsApproval {
                LabeledContent("需在系统设置中允许") {
                    Button("打开系统设置…") { controller.openSystemSettings() }
                }
            }
            if let message = controller.errorMessage {
                Text(verbatim: message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }
}

private struct SyncIntervalField: View {
    @Binding var minutes: Int
    @FocusState private var focused: Bool
    @State private var draft: String?
    @State private var invalid = false

    private var editing: Binding<String> {
        Binding { draft ?? String(minutes) } set: {
            draft = $0
            invalid = false
        }
    }

    private func save() {
        guard let draft else { return }
        guard let parsed = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)),
              AppModel.syncIntervalRange.contains(parsed) else {
            invalid = true
            return
        }
        if parsed != minutes { minutes = parsed }
        self.draft = nil
        invalid = false
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 5) {
                TextField("同步间隔（分钟）", text: editing)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 62)
                    .focused($focused)
                    .onSubmit(save)
                    .onChange(of: focused) { _, focused in
                        if !focused { save() }
                    }
                Text("分钟").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        } label: {
            Text("同步间隔")
            if invalid {
                Text("请输入 1–1440 之间的整数").foregroundStyle(.red)
            }
        }
    }
}

private struct MultiplierField: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    @Binding var value: Double
    @State private var draft: String?
    @Environment(\.locale) private var locale

    init(_ title: LocalizedStringKey, help: LocalizedStringKey, value: Binding<Double>) {
        self.title = title
        self.help = help
        _value = value
    }

    private var decimalSeparator: String { locale.decimalSeparator ?? "." }

    private func parse(_ text: String) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: decimalSeparator, with: ".")
        guard let v = Double(input), v > 0, v <= 100 else { return nil }
        return v
    }

    private var editing: Binding<String> {
        Binding {
            if let draft { return draft }
            let plain = String(value)
            let display = plain.hasSuffix(".0") ? String(plain.dropLast(2)) : plain
            return display.replacingOccurrences(of: ".", with: decimalSeparator)
        } set: { text in
            draft = text
            if let parsed = parse(text), parsed != value { value = parsed }
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(title, text: editing, prompt: Text("1"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 88)
                    .onSubmit {
                        if let draft, parse(draft) != nil { self.draft = nil }
                    }
                Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        } label: {
            Text(title)
            if let draft, parse(draft) == nil {
                Label("请输入大于 0 且不超过 100 的数值", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            } else {
                Text(help)
            }
        }
    }
}
