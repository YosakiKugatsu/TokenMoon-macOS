// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import Foundation
import Observation
import TokenMoonCore
import UniformTypeIdentifiers

enum QuickUsageDimension: String, CaseIterable, Identifiable, Sendable {
    case model, tool, session

    var id: Self { self }
    var label: String {
        switch self {
        case .model: "模型"
        case .tool: "工具"
        case .session: "会话"
        }
    }
}

enum QuickUsageScope: String, CaseIterable, Identifiable, Sendable {
    case local, all

    var id: Self { self }
    var label: String { self == .local ? "本机" : "全部" }
}

struct QuickUsageRow: Identifiable, Sendable {
    let id: String
    let label: String
    let sessionID: String?
    let deviceID: String?
    var tokens: Int64 = 0

    mutating func add(_ count: Int64) {
        let (total, overflow) = tokens.addingReportingOverflow(count)
        tokens = overflow ? .max : total
    }
}

struct QuickUsageBin: Identifiable {
    let cell: UsageMiniTrendWindow.Cell
    let metrics: UsageMetrics
    var id: Date { cell.id }
}

private struct QuickUsageGroups {
    private var byModel: [String: QuickUsageRow] = [:]
    private var byTool: [String: QuickUsageRow] = [:]
    private var bySession: [String: QuickUsageRow] = [:]

    mutating func add(_ request: UsageRequest, tokens: Int64, title: String?) {
        if let model = request.modelFacetIdentity {
            byModel[model, default: .init(id: model, label: model, sessionID: nil, deviceID: nil)].add(tokens)
        }
        let tool = request.agentGroup
        byTool[tool.rawValue, default: .init(id: tool.rawValue, label: tool.label, sessionID: nil, deviceID: nil)].add(tokens)
        let session = request.sessionKey
        let shortID = request.sessionID.count > 8 ? "…" + request.sessionID.suffix(8) : request.sessionID
        bySession[session, default: .init(id: session, label: title ?? "\(request.agent.label) · \(shortID)",
                                         sessionID: request.sessionID, deviceID: request.deviceID.lowercased())].add(tokens)
    }

    var sorted: [QuickUsageDimension: [QuickUsageRow]] {
        let groups: [QuickUsageDimension: [String: QuickUsageRow]] = [.model: byModel, .tool: byTool, .session: bySession]
        return groups.mapValues { rows in
            rows.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
        }
    }
}

struct DashboardFilterSelection: Equatable, Sendable {
    var models: Set<String> = []
    var devices: Set<String> = []
    var agents: Set<UsageAgentGroup> = []
    var tiers: Set<ServiceTier> = []
    var statuses: Set<RequestStatusFacet> = []
    var accounts: Set<UsageAccountFacet> = []
    var excludesAPIKeys = false

    /// The API-key exclusion affects the results, but is not a picked facet.
    var isEmpty: Bool { selectedCount == 0 && !excludesAPIKeys }
    var selectedCount: Int { models.count + devices.count + agents.count + tiers.count + statuses.count + accounts.count }

    mutating func clearSelections() {
        self = .init(excludesAPIKeys: excludesAPIKeys)
    }

    func includes(_ request: UsageRequest, accountResolver: inout UsageAccountFacet.Resolver) -> Bool {
        guard (models.isEmpty || request.modelFacetIdentity.map { models.contains($0) } == true)
            && (devices.isEmpty || devices.contains(request.deviceID))
            && (agents.isEmpty || agents.contains(request.agentGroup))
            && (tiers.isEmpty || tiers.contains(ServiceTier(request.requestedServiceTier)))
            && (statuses.isEmpty || statuses.contains { $0.includes(request) }) else { return false }
        return accountResolver.includes(request, selected: accounts, excludesAPIKeys: excludesAPIKeys)
    }
}

@Observable @MainActor
final class AppModel {
    var range: UsageRange = .last7Days { didSet { if oldValue != range { rebuild() } } }
    private(set) var customHours: ClosedRange<Date> {
        didSet { if range == .custom && oldValue != customHours { rebuild() } }
    }
    func useCustomHours(_ hours: ClosedRange<Date>) {
        customHours = hours
        range = .custom
    }
    var filters = DashboardFilterSelection(excludesAPIKeys: true) {
        didSet {
            guard oldValue != filters else { return }
            if oldValue.models != filters.models { chartFilterChanged(.model, selectionCount: filters.models.count) }
            if oldValue.devices != filters.devices { chartFilterChanged(.device, selectionCount: filters.devices.count) }
            if oldValue.accounts != filters.accounts { chartFilterChanged(.account, selectionCount: filters.accounts.count) }
            if oldValue.agents != filters.agents { chartFilterChanged(.agent, selectionCount: filters.agents.count) }
            if oldValue.tiers != filters.tiers { chartFilterChanged(.requestedTier, selectionCount: filters.tiers.count) }
            if oldValue.statuses != filters.statuses { chartFilterChanged(.status, selectionCount: filters.statuses.count) }
            rebuild()
        }
    }
    var displayTimeZoneID: String {
        didSet {
            guard oldValue != displayTimeZoneID else { return }
            defaults.set(displayTimeZoneID, forKey: "displayTimeZoneID")
            resetDisplayClock()
        }
    }
    private var displayClockRevision = 0
    var displayTimeZone: TimeZone {
        _ = displayClockRevision
        return UsageDisplayTime.timeZone(for: displayTimeZoneID)
    }
    var displayCalendar: Calendar { UsageDisplayTime.calendar(in: displayTimeZone) }

    let thisDeviceID: String
    var deviceName: String {
        didSet {
            guard oldValue != deviceName else { return }
            defaults.set(deviceName, forKey: "deviceName")
            deviceNames[thisDeviceID] = deviceName
            subscriptionInputsChanged()
        }
    }
    private(set) var models: [String] = []
    private(set) var deviceNames: [String: String] = [:]
    private(set) var devices: [String] = []
    private(set) var agents: [UsageAgentGroup] = []
    private(set) var requestTiers: [ServiceTier] = []
    private(set) var requestStatuses: [RequestStatusFacet] = []
    private(set) var requestAccounts: [UsageAccountFacet] = []
    @ObservationIgnored private var requestAccountNames: [UsageAccountFacet: String] = [:]
    @ObservationIgnored private var rebuildingDashboard = false
    private(set) var filteredRequests: [UsageRequest] = []
    private(set) var unpricedDashboardRequests: [UsageRequest] = []
    private(set) var snapshot: UsageSnapshot?
    private(set) var chartSeriesData: ChartSeriesData = .empty
    private(set) var modelColorSlots: [String: Int]
    private var chartSeriesColorSlots: [String: [String: Int]] = [:]
    @ObservationIgnored private var chartGroupingRecency: [UsageChartDimension] = []
    private(set) var chartGroupingOverride: UsageChartDimension?

    func chartFilterChanged(_ dimension: UsageChartDimension, selectionCount: Int) {
        chartGroupingRecency.removeAll { $0 == dimension }
        if selectionCount > 1 { chartGroupingRecency.append(dimension) }
    }

    func setChartGrouping(_ dimension: UsageChartDimension?) {
        guard chartGroupingOverride != dimension else { return }
        chartGroupingOverride = dimension
        rebuild()
    }

    func chartColorSlot(for identity: String) -> Int? {
        let dimension = chartSeriesData.grouping
        return dimension == .model ? modelColorSlots[identity] : chartSeriesColorSlots[dimension.rawValue]?[identity]
    }

    private func rememberChartColors(_ chart: ChartSeriesData) {
        let dimension = chart.grouping
        guard dimension != .model else { return }
        let key = dimension.rawValue
        let current = chartSeriesColorSlots[key] ?? [:]
        let slots = ModelColorSlots.adding(Set(chart.seriesIDs), to: current)
        guard slots != current else { return }
        chartSeriesColorSlots[key] = slots
        // Account series IDs contain ledger identities; keep their slots in memory.
        if dimension != .account {
            var persisted = chartSeriesColorSlots
            persisted.removeValue(forKey: UsageChartDimension.account.rawValue)
            defaults.set(persisted, forKey: "chartSeriesColorSlots")
        }
    }
    // Read-only presentation metadata. The persisted and synced ledgers remain usage-only.
    private(set) var sessionTitles: [String: String] = [:]
    private var menuTrendByScope: [QuickUsageScope: [Int64]] = [:]
    var menuTrendTokens: [Int64] { menuTrendByScope[quickUsageScope] ?? Array(repeating: 0, count: UsageMenuTrend.count) }
    // The status item always shows the rolling window, using the popup's device scope.
    var last24HourMetrics: UsageMetrics { quickRolling[quickUsageScope]?.metrics ?? .init() }
    private(set) var quickSelectedBinID: Date?
    private(set) var quickModelFilter: String?
    private var quickCells: [UsageMiniTrendWindow.Cell] = []
    private var quickBinsByScope: [QuickUsageScope: [Date: RollingQuickMetrics]] = [:]
    private var quickRolling: [QuickUsageScope: RollingQuickMetrics] = [:]
    var quickSelectedBin: UsageMiniTrendWindow.Cell? {
        guard let quickSelectedBinID else { return nil }
        return quickCells.first { $0.id == quickSelectedBinID }
    }
    private var quickSelectionMetrics: RollingQuickMetrics? {
        if let quickSelectedBin {
            return quickBinsByScope[quickUsageScope]?[quickSelectedBin.id]
        }
        return quickRolling[quickUsageScope]
    }
    private func quickFilteredMetrics(_ source: RollingQuickMetrics?) -> UsageMetrics {
        if let quickModelFilter { return source?.models[quickModelFilter] ?? .init() }
        return source?.metrics ?? .init()
    }
    var quickShowsLast24Hours: Bool { quickSelectedBin == nil }
    var quickMetrics: UsageMetrics { quickFilteredMetrics(quickSelectionMetrics) }
    var quickTrendMetrics: UsageMetrics { quickFilteredMetrics(quickRolling[quickUsageScope]) }
    var quickTimeline: [QuickUsageBin] {
        let bins = quickBinsByScope[quickUsageScope]
        return quickCells.map { QuickUsageBin(cell: $0, metrics: quickFilteredMetrics(bins?[$0.id])) }
    }
    var quickBreakdown: [QuickUsageRow] {
        quickSelectionMetrics?.groups[quickUsageDimension] ?? []
    }

    func selectQuickBin(_ id: Date) {
        guard quickCells.contains(where: { $0.id == id }) else { return }
        quickSelectedBinID = id == quickSelectedBinID ? nil : id
    }
    func showQuickLast24Hours() { quickSelectedBinID = nil }
    func refreshQuickWindow() {
        if ready { rebuildQuickLook() }
    }
    func toggleQuickModel(_ name: String) {
        quickModelFilter = quickModelFilter == name ? nil : name
    }
    func clearQuickModel() { quickModelFilter = nil }
    func resetQuickLook() {
        quickSelectedBinID = nil
        quickModelFilter = nil
    }
    var metrics: UsageMetrics { snapshot?.metrics ?? .init() }
    var timeline: [UsageBucket] { snapshot?.timeline ?? [] }
    var timelineInterval: UsageBucketInterval { snapshot?.timelineInterval ?? .day }
    func setChartBucketTarget(_ target: Int) {
        guard target != chartTargetBucketCount else { return }
        chartTargetBucketCount = target
        rebuild()
    }
    var sessions: [UsageSession] { snapshot?.sessions ?? [] }

    var fastMultiplier: Double { didSet { if Self.validFactor(fastMultiplier) { defaults.set(fastMultiplier, forKey: "fastMultiplier"); pricingChanged() } } }
    var ultraFastMultiplier: Double { didSet { if Self.validFactor(ultraFastMultiplier) { defaults.set(ultraFastMultiplier, forKey: "ultraFastMultiplier"); pricingChanged() } } }
    private(set) var fastMultipliersByChannel: [String: Double]
    func setFastMultiplier(_ value: Double?, channel: String) {
        guard value.map(Self.validFactor) ?? true, fastMultipliersByChannel[channel] != value else { return }
        fastMultipliersByChannel[channel] = value
        defaults.set(fastMultipliersByChannel, forKey: "fastMultipliersByChannel")
        pricingChanged()
    }
    var priceSource: PriceSource { didSet { defaults.set(priceSource.rawValue, forKey: "priceSource"); pricingChanged() } }
    var priceDescription: String {
        let count = priceSource == .omc ? omcPrices.count : publicPrices.count
        return count == 0 ? "未导入价目表" : "\(count) 个有价模型"
    }

    var webDAVURL: String { didSet { if oldValue != webDAVURL { connectionEdited() } } }
    var webDAVUsername: String { didSet { if oldValue != webDAVUsername { connectionEdited() } } }
    var webDAVPassword = ""
    var autoSync: Bool {
        didSet {
            guard autoSync != oldValue else { return }
            defaults.set(autoSync, forKey: "autoSync")
            if autoSync {
                lastSyncAttempt = nil
                syncFailures = 0
            }
            syncSleep?.cancel()
        }
    }
    static let syncIntervalRange = 1...1440
    private static let defaultSyncIntervalMinutes = 5
    var syncIntervalMinutes: Int {
        didSet {
            guard syncIntervalMinutes != oldValue else { return }
            let minutes = min(Self.syncIntervalRange.upperBound, max(Self.syncIntervalRange.lowerBound, syncIntervalMinutes))
            if minutes != syncIntervalMinutes { syncIntervalMinutes = minutes }
            defaults.set(minutes, forKey: "syncIntervalMinutes")
            syncSleep?.cancel()
        }
    }
    var showsMenuBarItem: Bool { didSet { defaults.set(showsMenuBarItem, forKey: "showsMenuBarItem") } }
    var menuBarDisplayMode: MenuBarDisplayMode { didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") } }
    var menuBarPrimaryMetric: MenuBarUsageMetric { didSet { defaults.set(menuBarPrimaryMetric.rawValue, forKey: "menuBarPrimaryMetric") } }
    var menuBarSecondaryMetric: MenuBarUsageMetric { didSet { defaults.set(menuBarSecondaryMetric.rawValue, forKey: "menuBarSecondaryMetric") } }
    var menuBarQuotaSource: MenuBarQuotaSource { didSet { defaults.set(menuBarQuotaSource.rawValue, forKey: "menuBarQuotaSource") } }
    var showsMenuTrend: Bool { didSet { defaults.set(showsMenuTrend, forKey: "showsMenuTrend") } }
    var automaticRateYAxis: Bool { didSet { defaults.set(automaticRateYAxis, forKey: "automaticRateYAxis") } }
    var quickUsageDimension: QuickUsageDimension {
        didSet {
            defaults.set(quickUsageDimension.rawValue, forKey: "quickUsageDimension")
            if quickUsageDimension != .model { clearQuickModel() }
        }
    }
    var quickUsageScope: QuickUsageScope {
        didSet {
            guard oldValue != quickUsageScope else { return }
            defaults.set(quickUsageScope.rawValue, forKey: "quickUsageScope")
            showQuickLast24Hours()
        }
    }
    private(set) var collectionStatusMessage = ""
    private(set) var syncStatusMessage = ""
    private(set) var pricingStatusMessage = ""
    private(set) var collectionIssue = false
    private(set) var syncIssue = false
    private(set) var pricingIssue = false
    private(set) var lastCollection: Date?
    var statusMessage: String {
        if syncIssue { return syncStatusMessage }
        if pricingIssue { return pricingStatusMessage }
        return collectionStatusMessage
    }
    private(set) var isRefreshing = false
    private(set) var isSyncing = false
    private(set) var isImporting = false
    private(set) var isRefreshingModelNames = false
    private(set) var lastSync: Date?
    private(set) var reports: [CollectionReport] = []
    private(set) var quotaAccounts: [QuotaAccount] = []
    private(set) var isQuotaRefreshing = false
    private(set) var quotaLastRefresh: Date?
    private(set) var quotaStatusMessage = ""
    private(set) var quotaDepletionOptions: [QuotaDepletionOption] = []
    private(set) var quotaDepletionChart: QuotaDepletionChart?
    private(set) var isQuotaDepletionChartLoading = false
    private struct SubscriptionUsageSnapshot {
        let at: Date
        let source: PriceSource
        let windows: [UsageQuotaInsights.Window]
    }
    private var subscriptionUsageSnapshot: SubscriptionUsageSnapshot?
    var subscriptionUsageEstimates: [UsageQuotaInsights.Window] { subscriptionUsageSnapshot?.windows ?? [] }
    var subscriptionUsageAsOf: Date? { subscriptionUsageSnapshot?.at }
    var subscriptionUsagePriceSource: PriceSource { subscriptionUsageSnapshot?.source ?? priceSource }
    private(set) var subscriptionInsightAgentOrder: [UsageQuotaInsights.Provider] {
        didSet { defaults.set(subscriptionInsightAgentOrder.map(\.rawValue), forKey: "subscriptionInsightAgentOrder") }
    }
    private(set) var isSubscriptionUsageEstimating = false
    private var quotaHistory: [QuotaObservation] = []
    @ObservationIgnored private let quotaStore: QuotaHistoryStore
    @ObservationIgnored private let nativeQuotaStore: NativeQuotaHistoryStore
    @ObservationIgnored private var nativeQuotaArchive: [QuotaWireObservation] = []
    @ObservationIgnored private var quotaDepletionTask: Task<Void, Never>?
    @ObservationIgnored private var quotaDepletionChartTask: Task<Void, Never>?
    @ObservationIgnored private var quotaDepletionChartID: String?
    @ObservationIgnored private var subscriptionUsageTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionUsageVisible = false
    @ObservationIgnored private var subscriptionInputsRevision = 0
    @ObservationIgnored private var subscriptionCompletedKey: SubscriptionUsageKey?
    @ObservationIgnored private var subscriptionRunningKey: SubscriptionUsageKey?
    @ObservationIgnored private var subscriptionWorkID: UUID?
    @ObservationIgnored private var subscriptionQueuedKey: SubscriptionUsageKey?
    @ObservationIgnored private var subscriptionNextBoundary: Date?
    @ObservationIgnored private var subscriptionPeerObservations: [QuotaWireObservation] = []
    @ObservationIgnored private var subscriptionIndexedConnection: DAVConnection?
    @ObservationIgnored private let quotaRefreshEnabled: Bool
    @ObservationIgnored private var quotaLastAttempt: Date?
    @ObservationIgnored private var codexCreatorAccounts = CodexCreatorAccounts()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let confirmedNativeAccounts: ConfirmedNativeAccounts?
    @ObservationIgnored private let store: LedgerStore
    @ObservationIgnored private let collectors = UsageCollectors()
    @ObservationIgnored private var localRequests: [UsageRequest] = []
    @ObservationIgnored private var supersededRequestIDs: Set<String> = []
    @ObservationIgnored private var lastScanRows: [UsageRequest]?
    @ObservationIgnored private var pendingCollection = false
    @ObservationIgnored private var needsInitialReconciliation = false
    @ObservationIgnored private var pendingSyncReconciliation = false
    @ObservationIgnored private var syncOperation: Task<WebDAVSyncResult, Error>?
    @ObservationIgnored private var passwordReadFailed = false
    @ObservationIgnored private var syncSleep: Task<Void, Error>?
    @ObservationIgnored private var lastSyncAttempt: ContinuousClock.Instant?
    @ObservationIgnored private var syncFailures = 0
    @ObservationIgnored private var remainingManualSyncRetries = 0
    @ObservationIgnored private var ledgerStartupIssues: [String] = []
    @ObservationIgnored private var imported = ImportedLedger(requests: [], deviceNames: [:])
    @ObservationIgnored private var remote: RemoteLedger?
    @ObservationIgnored private var allRequests: [UsageRequest] = []
    @ObservationIgnored private var costsByRequest: [UsageKey: RequestCost] = [:]
    @ObservationIgnored private var pricingRevision = 0
    @ObservationIgnored private var indexedPricingRevision = -1
    @ObservationIgnored private var indexedDeviceNames: [String: String] = [:]
    @ObservationIgnored private var dataTask: Task<Void, Never>?
    @ObservationIgnored private var dataUpdatePending = false
    @ObservationIgnored private var dashboardWindowVisible = false
    @ObservationIgnored private var dashboardUpdatePending = false
    @ObservationIgnored private var dashboardTask: Task<Void, Never>?
    @ObservationIgnored private var dashboardWindowFacets: DashboardWindowFacets?
    @ObservationIgnored private var quickLookTask: Task<Void, Never>?
    @ObservationIgnored private var lastClockDay: Date?
    @ObservationIgnored private var lastClockZone: String?
    @ObservationIgnored private var lastDashboardMinute: Int?
    @ObservationIgnored private var nextQuickBoundary: Date?
    @ObservationIgnored private var chartTargetBucketCount = UsageChartResolution.defaultBucketCount
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ready = false
    private var customRoots: [String: [String]]
    private var omcPrices: PriceBook = .empty
    private var publicPrices: PriceBook = .empty
    private var modelNames: ModelNames = .empty
    private var modelNameOverrides: [String: String] = [:]
    private var modelNamesUpdated: Date?
    private var modelNamesError = false

    init() {
        let override = ProcessInfo.processInfo.environment["TOKENMOON_DATA_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: "TokenMoon Community", directoryHint: .isDirectory)
        let defaults = override == nil ? UserDefaults.standard : UserDefaults(suiteName: "TokenMoon-QA-\(directory.lastPathComponent)") ?? .standard
        self.defaults = defaults
        self.store = LedgerStore(directory: directory)
        self.quotaStore = QuotaHistoryStore(directory: directory)
        self.nativeQuotaStore = NativeQuotaHistoryStore(directory: directory)
        self.quotaRefreshEnabled = override == nil
        let localID = (defaults.string(forKey: "deviceID") ?? UUID().uuidString).lowercased()
        self.thisDeviceID = localID
        let confirmed = defaults.dictionary(forKey: "confirmedNativeAccounts") as? [String: String]
        self.confirmedNativeAccounts = confirmed?["deviceID"]?.lowercased() == localID
            ? ConfirmedNativeAccounts(ownerDeviceID: localID, codexEmail: confirmed?["codex"],
                                      claudeCodeEmail: confirmed?["claude-code"])
            : nil
        self.deviceName = defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "这台 Mac"
        let zoneID = defaults.string(forKey: "displayTimeZoneID") ?? UsageDisplayTime.system
        self.displayTimeZoneID = zoneID
        self.modelColorSlots = ModelColorSlots.validated(defaults.dictionary(forKey: "modelChartColorSlots") as? [String: Int] ?? [:])
        self.chartSeriesColorSlots = (defaults.dictionary(forKey: "chartSeriesColorSlots") as? [String: [String: Int]] ?? [:])
            .mapValues(ModelColorSlots.validated)
        self.customHours = UsageDisplayTime.defaultHours(now: .now,
            calendar: UsageDisplayTime.calendar(in: UsageDisplayTime.timeZone(for: zoneID)))
        self.fastMultiplier = (defaults.object(forKey: "fastMultiplier") as? Double).flatMap { Self.validFactor($0) ? $0 : nil } ?? 2.5
        self.fastMultipliersByChannel = (defaults.dictionary(forKey: "fastMultipliersByChannel") as? [String: Double] ?? [:])
            .filter { Self.validFactor($0.value) }
        self.ultraFastMultiplier = (defaults.object(forKey: "ultraFastMultiplier") as? Double).flatMap { Self.validFactor($0) ? $0 : nil } ?? 1
        self.priceSource = defaults.string(forKey: "priceSource").flatMap(PriceSource.init(rawValue:)) ?? .publicCatalog
        self.webDAVURL = defaults.string(forKey: "webDAVURL") ?? ""
        self.webDAVUsername = defaults.string(forKey: "webDAVUsername") ?? ""
        self.autoSync = defaults.bool(forKey: "autoSync")
        let storedInterval = defaults.integer(forKey: "syncIntervalMinutes")
        self.syncIntervalMinutes = Self.syncIntervalRange.contains(storedInterval) ? storedInterval : Self.defaultSyncIntervalMinutes
        self.showsMenuBarItem = defaults.object(forKey: "showsMenuBarItem") as? Bool ?? true
        self.menuBarDisplayMode = defaults.string(forKey: "menuBarDisplayMode").flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .usage
        self.menuBarPrimaryMetric = defaults.string(forKey: "menuBarPrimaryMetric")
            .flatMap(MenuBarUsageMetric.init(rawValue:)) ?? .tokens
        self.menuBarSecondaryMetric = defaults.string(forKey: "menuBarSecondaryMetric")
            .flatMap(MenuBarUsageMetric.init(rawValue:)) ?? .cost
        self.menuBarQuotaSource = defaults.string(forKey: "menuBarQuotaSource").flatMap(MenuBarQuotaSource.init(rawValue:)) ?? .automatic
        self.showsMenuTrend = defaults.object(forKey: "showsMenuTrend") as? Bool ?? true
        self.automaticRateYAxis = defaults.object(forKey: "automaticRateYAxis") as? Bool ?? true
        self.subscriptionInsightAgentOrder = SubscriptionAgentOrder.restore(defaults.stringArray(forKey: "subscriptionInsightAgentOrder") ?? [])
        self.quickUsageDimension = defaults.string(forKey: "quickUsageDimension")
            .flatMap(QuickUsageDimension.init(rawValue:)) ?? .model
        self.quickUsageScope = defaults.string(forKey: "quickUsageScope")
            .flatMap(QuickUsageScope.init(rawValue:)) ?? .local
        self.customRoots = defaults.dictionary(forKey: "roots") as? [String: [String]] ?? [:]
        defaults.set(thisDeviceID, forKey: "deviceID")
        loadPassword()
    }

    func moveSubscriptionInsightAgent(_ source: UsageQuotaInsights.Provider,
                                      to target: UsageQuotaInsights.Provider) {
        if let order = SubscriptionAgentOrder.moving(source, to: target, saved: subscriptionInsightAgentOrder,
                                                     available: Set(subscriptionUsageEstimates.map(\.provider))) {
            subscriptionInsightAgentOrder = order
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // Keep collection active when the dashboard closes and the menu item remains.
        Task { await run() }
    }

    private func run() async {
        defer { started = false }
        do { try await restoreStoredState() }
        catch is CancellationError { return }
        catch {
            collectionIssue = true
            collectionStatusMessage = "无法载入本机账本：\(error.localizedDescription)"
            return
        }
        guard !Task.isCancelled else { return }
        async let collection: Void = collectionLoop()
        async let quota: Void = quotaLoop()
        async let sync: Void = syncLoop()
        async let clock: Void = clockLoop()
        _ = await (collection, quota, sync, clock)
    }

    private func restoreStoredState() async throws {
        let state = try await store.load()
        nativeQuotaArchive = await nativeQuotaStore.load()
        var issues = state.issues
        let rule = confirmedNativeAccounts
        let adjusted = try? await Self.background {
            (Self.applyingConfirmedAccounts(rule, to: state.local.requests),
             Self.applyingConfirmedAccounts(rule, to: state.imported.requests))
        }
        try Task.checkCancellation()
        localRequests = adjusted?.0.rows ?? state.local.requests
        supersededRequestIDs = state.local.supersededRequestIDs
        needsInitialReconciliation = state.needsInitialReconciliation
        imported = .init(requests: adjusted?.1.rows ?? state.imported.requests, deviceNames: state.imported.deviceNames)
        if adjusted?.0.changed == true && !state.needsInitialReconciliation {
            do {
                try await store.save(LocalLedger(requests: localRequests, supersededRequestIDs: supersededRequestIDs),
                                     file: LedgerStore.localFile)
            } catch {
                // Collection compares against the saved version and retries the write.
                localRequests = state.local.requests
                issues.append("已确认账号暂未写入本机账本")
            }
        }
        if adjusted?.1.changed == true {
            do { try await store.save(imported, file: "imports.json") }
            catch { issues.append("已确认账号暂未写入导入账本") }
        }
        remote = state.remote
        omcPrices = state.omc
        publicPrices = state.publicCatalog
        modelNames = state.modelNames
        modelNamesUpdated = state.modelNamesUpdated
        ledgerStartupIssues = issues
        collectionIssue = !issues.isEmpty
        collectionStatusMessage = issues.joined(separator: "；")
        restoreSyncStatus()
        ready = true
        updateAvailable()
        refreshClockBoundary()
    }

    private func collectionLoop() async {
        await collect()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { break }
            await collect()
        }
    }

    private func quotaLoop() async {
        guard quotaRefreshEnabled else { return }
        while !Task.isCancelled {
            await updateQuota()
            do { try await Task.sleep(for: .seconds(120)) } catch { break }
        }
    }

    private func syncLoop() async {
        // Give a first local scan a head start without waiting on it or
        // coupling its future refreshes to network latency.
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        while !Task.isCancelled {
            let delay: Duration
            if (!autoSync && remainingManualSyncRetries == 0) || connection == nil || isSyncing {
                // Edits and manual sync completion wake the loop immediately.
                delay = .seconds(86_400)
            } else if needsInitialReconciliation || (lastCollection == nil && isRefreshing) {
                delay = .seconds(1)
            } else {
                let normalSeconds = syncIntervalMinutes * 60
                let retrySeconds = 15 << max(0, syncFailures - 1)
                let seconds = syncFailures == 0 ? normalSeconds : min(normalSeconds, 300, retrySeconds)
                let interval = Duration.seconds(seconds)
                let remaining = lastSyncAttempt.map { ContinuousClock.now.duration(to: $0.advanced(by: interval)) } ?? .zero
                if remaining <= .zero {
                    if remainingManualSyncRetries > 0 { remainingManualSyncRetries -= 1 }
                    await synchronize()
                    continue
                }
                delay = remaining
            }
            let wait = Task { try await Task.sleep(for: delay) }
            syncSleep = wait
            await withTaskCancellationHandler {
                _ = await wait.result
            } onCancel: {
                wait.cancel()
            }
            syncSleep = nil
        }
    }

    private func clockLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(20)) } catch { break }
            refreshClockBoundary()
        }
    }

    func requests(for session: UsageSession) -> [UsageRequest] { snapshot?.sessionRequests[session.id] ?? [] }
    func sessionTitle(for key: String) -> String? { sessionTitles[key] }
    func requestCost(_ request: UsageRequest) -> RequestCost {
        if indexedPricingRevision == pricingRevision, let cached = costsByRequest[request.key] { return cached }
        return engine.cost(request)
    }
    func cost(_ request: UsageRequest) -> Double? { requestCost(request).usd }
    func modelDisplayName(_ id: String) -> String { modelNames.displayName(for: id) }
    func modelFilterOptionLabel(_ id: String) -> String { modelNameOverrides[id] ?? modelDisplayName(id) }
    func accountFilterOptionLabel(_ account: UsageAccountFacet) -> String { requestAccountNames[account] ?? account.label }
    var modelNamesDescription: String {
        if isRefreshingModelNames { return "正在从 models.dev 获取模型名称…" }
        if modelNamesError { return "更新失败，继续使用已保存的名称。" }
        if let modelNamesUpdated {
            return "models.dev · 更新于 \(formatDate(modelNamesUpdated, as: .dateTime.year().month(.abbreviated).day()))"
        }
        return "使用随应用附带的 models.dev 名称目录"
    }

    func refresh() {
        Task { await collect(queueIfBusy: true) }
        refreshQuota()
    }

    func refreshQuota() { Task { await updateQuota(force: true) } }

    private func updateQuota(force: Bool = false) async {
        guard quotaRefreshEnabled, !isQuotaRefreshing else { return }
        if !force, let quotaLastAttempt, Date.now.timeIntervalSince(quotaLastAttempt) < 115 { return }
        quotaLastAttempt = .now
        isQuotaRefreshing = true
        defer { isQuotaRefreshing = false }
        async let codex = try? CodexQuotaReader.readWithCreatorAccounts()
        async let others = OtherQuotaReader.read()
        let (codexReading, otherAccounts) = await (codex, others)
        let codexAccounts = codexReading?.accounts
        let newCreatorAccounts = codexReading?.creatorAccounts
        let creatorAccountsChanged = newCreatorAccounts.map { $0 != codexCreatorAccounts } ?? false
        if let newCreatorAccounts, creatorAccountsChanged { codexCreatorAccounts = newCreatorAccounts }
        let incoming = (codexAccounts ?? []) + otherAccounts
        let previous = Dictionary(quotaAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date.now
        let accounts = incoming.map { account in
            if account.agent == .codex {
                guard account.id == codexReading?.lastKnownAccountID else { return account }
                return NativeQuotaHistoryStore.lastKnownCodexAccount(
                    account, from: nativeQuotaArchive, previous: previous[account.id], now: now
                ) ?? account
            }
            if account.windows.isEmpty, let old = previous[account.id], !old.windows.isEmpty {
                return old.asLastKnown(note: account.note)
            }
            return account
        }
        // No Codex identity means no verified account/workspace to attach a reading to.
        quotaAccounts = accounts.sorted { ($0.agent.rawValue, $0.id) < ($1.agent.rawValue, $1.id) }
        let observed = incoming.filter { !$0.windows.isEmpty && $0.liveObservationAt != nil }
        if let latest = observed.compactMap(\.liveObservationAt).max() { quotaLastRefresh = latest }
        quotaStatusMessage = observed.isEmpty ? "未取得新的官方额度读数" : ""
        let identifiedObservations = observed.filter { $0.id != "antigravity:ambient-cli" }
        quotaHistory = await quotaStore.record(identifiedObservations)
        nativeQuotaArchive = await nativeQuotaStore.record(identifiedObservations)
        rebuildQuotaDepletion()
        subscriptionInputsChanged()
        if let issue = await quotaStore.persistenceIssue {
            quotaStatusMessage = [quotaStatusMessage, issue.description].filter { !$0.isEmpty }.joined(separator: "；")
        }
        if creatorAccountsChanged { await collect(queueIfBusy: true) }
    }

    func forecast(for account: QuotaAccount, window: QuotaWindow) -> QuotaForecastDisplay? {
        if account.id == "antigravity:ambient-cli" {
            return .init(headline: "暂无预测", detail: "客户端未提供可用于区分账号的标识")
        }
        guard let prediction = QuotaForecast.estimate(account: account, window: window, observations: quotaHistory) else { return nil }
        let title: String
        if prediction.lastsUntilReset {
            title = "预计可用到重置"
        } else if let end = prediction.exhaustsAt {
            title = "预计 \(formatDate(end, as: .dateTime.month().day().hour().minute())) 用完"
        } else {
            return nil
        }
        let rate = prediction.percentagePointsPerHour.formatted(.number.precision(.fractionLength(1)))
        return .init(headline: title, detail: "本周期 \(prediction.sampleCount) 次读数 · 每小时约消耗 \(rate) 个百分点")
    }

    private func collect(queueIfBusy: Bool = false) async {
        guard ready else { return }
        if isRefreshing {
            if queueIfBusy { pendingCollection = true }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            pendingCollection = false
            await collectOnce()
        } while pendingCollection && !Task.isCancelled
    }

    private func collectOnce() async {
        let deviceID = thisDeviceID
        let collectors = collectors
        let previousScan = lastScanRows
        let prior = localRequests
        let priorSuperseded = supersededRequestIDs
        let checkpoint = needsInitialReconciliation
        let creatorAccounts = codexCreatorAccounts
        let rule = confirmedNativeAccounts
        let roots = Dictionary(uniqueKeysWithValues: Agent.localCollectors.compactMap { agent in
            customRoots[agent.rawValue].map { paths in
                (agent, paths.map { URL(fileURLWithPath: $0) })
            }
        })
        do {
            let (result, newLedger) = try await Self.background {
                let result = try collectors.scan(deviceID: deviceID, roots: roots, codexCreatorAccounts: creatorAccounts)
                let tombstones = priorSuperseded.union(result.supersededRequestIDs)
                guard checkpoint || previousScan != result.requests || tombstones != priorSuperseded else {
                    return (result, nil as LocalLedger?)
                }
                let merged = try Self.merged([prior, result.requests], ownDevice: deviceID, superseded: tombstones)
                let rows = Self.applyingConfirmedAccounts(rule, to: merged).rows
                return (result, checkpoint || rows != prior || tombstones != priorSuperseded
                    ? LocalLedger(requests: rows, supersededRequestIDs: tombstones) : nil)
            }
            try Task.checkCancellation()
            reports = result.reports
            let titlesChanged = sessionTitles != result.sessionTitles
            if titlesChanged { sessionTitles = result.sessionTitles }
            if let newLedger {
                try await store.save(newLedger, file: LedgerStore.localFile)
                localRequests = newLedger.requests
                if newLedger.supersededRequestIDs != supersededRequestIDs && isSyncing {
                    pendingSyncReconciliation = true
                    syncOperation?.cancel()
                }
                supersededRequestIDs = newLedger.supersededRequestIDs
                updateAvailable()
            } else if titlesChanged {
                rebuildQuickLook()
            }
            lastScanRows = result.requests
            needsInitialReconciliation = false
            lastCollection = .now
            collectionIssue = !ledgerStartupIssues.isEmpty
            let collected = result.requests.isEmpty ? "采集完成 · 本轮没有可读取的请求" : "采集完成 · \(result.requests.count.formatted()) 条本机请求"
            collectionStatusMessage = ([collected] + ledgerStartupIssues).joined(separator: "；")
        } catch is CancellationError {
            return
        } catch {
            collectionIssue = true
            collectionStatusMessage = "采集失败：\(error.localizedDescription)"
        }
    }

    func sync() { Task { await synchronize(manual: true) } }

    private var connection: DAVConnection? {
        let raw = webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.host != nil, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return .init(url: url, username: webDAVUsername)
    }

    private func synchronize(manual: Bool = false) async {
        guard ready, !isSyncing else { return }
        guard let connection else {
            syncIssue = true
            syncStatusMessage = "请填写完整的 WebDAV 目录地址。"
            return
        }
        guard !needsInitialReconciliation else {
            syncStatusMessage = "等待首次本机采集完成后再同步"
            return
        }
        if manual {
            syncFailures = 0
            remainingManualSyncRetries = 3
        }
        var failed: Bool?
        isSyncing = true
        defer {
            syncOperation = nil
            isSyncing = false
            if connection == self.connection, let failed {
                lastSyncAttempt = .now
                if failed {
                    syncFailures = min(syncFailures + 1, 6)
                } else {
                    syncFailures = 0
                    remainingManualSyncRetries = 0
                }
            }
            syncSleep?.cancel()
            if pendingSyncReconciliation && !Task.isCancelled {
                pendingSyncReconciliation = false
                Task { await synchronize() }
            }
        }
        if webDAVPassword.isEmpty, passwordReadFailed {
            // An unavailable Keychain item is not the same as an empty password.
            // Retry the read after login/unlock without deleting the saved item.
            loadPassword()
            if passwordReadFailed { failed = true; return }
        }
        let password = webDAVPassword
        let client = WebDAVClient(configuration: .init(url: connection.url, username: connection.username, password: password))
        do {
            if manual {
                try WebDAVPassword.save(password, url: connection.url, username: connection.username)
            } else {
                try WebDAVPassword.withoutUserInteraction {
                    try WebDAVPassword.save(password, url: connection.url, username: connection.username)
                }
            }
            let priorCache = remote.flatMap { $0.connection == connection ? $0 : nil }
            let deviceID = thisDeviceID
            let currentName = deviceName
            let tombstones = supersededRequestIDs
            let imports = imported.requests
            let local = localRequests
            let quotaToPublish = nativeQuotaArchive
            let (publishable, shardCache) = try await Self.background {
                let publishable = try Self.merged([imports.filter { $0.deviceID.lowercased() == deviceID }, local],
                                              ownDevice: deviceID, superseded: tombstones)
                let cache = priorCache?.cachedShards ?? priorCache.flatMap { previous in
                    client.legacyShardCache(requests: previous.legacyRequests, deviceNames: previous.deviceNames,
                                            capturedAt: previous.date ?? .distantPast)
                }
                return (publishable, cache)
            }
            guard connection == self.connection else { return }
            guard tombstones == supersededRequestIDs else {
                pendingSyncReconciliation = true
                return
            }
            let operation = Task {
                try await client.sync(deviceID: deviceID, deviceName: currentName, requests: publishable,
                                      cachedShards: shardCache, supersededRequestIDs: tombstones,
                                      quotaObservations: quotaToPublish)
            }
            syncOperation = operation
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard connection == self.connection, tombstones == supersededRequestIDs else { return }
            let checkpoint = priorCache.flatMap { prior -> UUID? in
                guard let previous = prior.cachedShards, result.cachedShards.hasSameVersions(as: previous),
                      prior.deviceNames == result.deviceNames else { return nil }
                return prior.checkpoint
            }
            let cache = RemoteLedger(connection: connection, legacyRequests: [], deviceNames: result.deviceNames,
                                     date: result.issues.isEmpty ? .now : priorCache?.date, cachedShards: result.cachedShards,
                                     issueMessages: result.issues.map(\.message), checkpoint: checkpoint ?? UUID())
            if let checkpoint {
                try await store.save(RemoteLedgerStatus(checkpoint: checkpoint, date: cache.date, issues: cache.issueMessages),
                                     file: "remote-status.json")
            } else {
                try await store.saveRemote(cache)
            }
            guard connection == self.connection else { return }
            remote = cache
            if checkpoint == nil { updateAvailable() }
            else { lastSync = cache.date }
            failed = !result.issues.isEmpty
            syncIssue = !result.issues.isEmpty
            if let first = result.issues.first {
                syncStatusMessage = "部分同步 · \(result.issues.count.formatted()) 个分片待处理 · \(first.message)"
            } else {
                syncStatusMessage = "同步完成 · \(result.deviceNames.count.formatted()) 台设备"
            }
        } catch is CancellationError {
            return
        } catch {
            guard connection == self.connection else { return }
            failed = true
            syncIssue = true
            syncStatusMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    func chooseRoot(for agent: Agent) {
        let panel = NSOpenPanel()
        panel.title = "选择 \(agent.label) 日志"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        customRoots[agent.rawValue] = panel.urls.map(\.path)
        defaults.set(customRoots, forKey: "roots")
        refresh()
    }

    func resetRoot(for agent: Agent) {
        customRoots.removeValue(forKey: agent.rawValue)
        defaults.set(customRoots, forKey: "roots")
        refresh()
    }

    func rootsDescription(for agent: Agent) -> String {
        if let paths = customRoots[agent.rawValue] {
            return paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " · ")
        }
        return "自动查找"
    }

    func importPrices() {
        guard let url = chooseJSON(title: "导入 \(priceSource.label) 价目表") else { return }
        let selectedSource = priceSource
        Task {
            do {
                let data = try await readFile(url)
                try await installPrices(data, as: selectedSource)
            } catch {
                pricingIssue = true
                pricingStatusMessage = "价目导入失败：\(error.localizedDescription)"
            }
        }
    }

    func updatePrices() {
        if priceSource == .omc { importPrices(); return }
        Task {
            do {
                let url = URL(string: "https://models.dev/api.json")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 20_000_000 else { throw PriceBookError.invalid }
                try await installPrices(data, as: .publicCatalog)
            } catch {
                pricingIssue = true
                pricingStatusMessage = "价目更新失败：\(error.localizedDescription)"
            }
        }
    }

    private static func fetchModelCatalog() async throws -> Data {
        let url = URL(string: "https://models.dev/api.json?type=all")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 20_000_000 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func refreshModelNames() {
        guard ready, !isRefreshingModelNames else { return }
        isRefreshingModelNames = true
        modelNamesError = false
        Task {
            defer { isRefreshingModelNames = false }
            do {
                let data = try await Self.fetchModelCatalog()
                let names = try await Task.detached(priority: .utility) { try ModelNames.decode(data) }.value
                let updated = try await store.saveModelNames(names)
                modelNames = ((try? ModelNames.bundled()) ?? .empty).merging(names)
                modelNamesUpdated = updated
                updateModelNameLabels()
            } catch {
                modelNamesError = true
            }
        }
    }

    private func installPrices(_ data: Data, as source: PriceSource) async throws {
        let book = try await Task.detached(priority: .utility) { try PriceBook.decode(data, as: source) }.value
        try await store.saveData(data, file: source == .omc ? "omc-prices.json" : "public-prices.json")
        if source == .omc { omcPrices = book } else { publicPrices = book }
        pricingChanged()
        pricingIssue = false
        pricingStatusMessage = "已更新 \(book.count) 个模型的\(source.label)价目"
    }

    func importUsage() {
        guard ready, !isImporting, let url = chooseJSON(title: "导入 TokenMoon 用量文件") else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let data = try await readFile(url)
                let incoming = try await Task.detached(priority: .utility) {
                    try LedgerCodec.decodePortable(data)
                }.value
                let prior = imported
                let rule = confirmedNativeAccounts
                let merged = try await Self.background {
                    let rows = try Self.merged([prior.requests, incoming.requests])
                    return ImportedLedger(requests: Self.applyingConfirmedAccounts(rule, to: rows).rows,
                                          deviceNames: prior.deviceNames.merging(incoming.deviceNames) { _, incoming in incoming })
                }
                try await store.save(merged, file: "imports.json")
                imported = merged
                updateAvailable()
                collectionIssue = !ledgerStartupIssues.isEmpty
                collectionStatusMessage = "已读取 \(incoming.requests.count.formatted()) 条请求并合并重复记录"
            } catch {
                collectionIssue = true
                collectionStatusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    func exportUsage() {
        let panel = NSSavePanel()
        panel.title = "导出全部用量"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TokenMoon-usage.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = allRequests
        let names = deviceNames
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    let data = try LedgerCodec.encoder().encode(PortableLedger(schemaVersion: 1, requests: rows, deviceNames: names))
                    try data.write(to: url, options: .atomic)
                }.value
                collectionIssue = !ledgerStartupIssues.isEmpty
                collectionStatusMessage = "已导出 \(rows.count.formatted()) 条请求"
            } catch {
                collectionIssue = true
                collectionStatusMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func connectionEdited() {
        syncOperation?.cancel()
        cancelSubscriptionUsage()
        subscriptionUsageSnapshot = nil
        lastSyncAttempt = nil
        syncFailures = 0
        remainingManualSyncRetries = 0
        syncSleep?.cancel()
        pendingSyncReconciliation = false
        syncIssue = false
        syncStatusMessage = ""
        if let connection {
            defaults.set(connection.url.absoluteString, forKey: "webDAVURL")
            defaults.set(webDAVUsername, forKey: "webDAVUsername")
        } else if webDAVURL.isEmpty {
            defaults.removeObject(forKey: "webDAVURL")
        }
        restoreSyncStatus()
        loadPassword()
        updateAvailable()
    }

    private func loadPassword() {
        passwordReadFailed = false
        guard let connection else { webDAVPassword = ""; return }
        do {
            webDAVPassword = try WebDAVPassword.withoutUserInteraction {
                try WebDAVPassword.read(url: connection.url, username: connection.username)
            } ?? ""
        }
        catch {
            passwordReadFailed = true
            webDAVPassword = ""
            syncIssue = true
            syncStatusMessage = "无法读取钥匙串：\(error.localizedDescription)"
        }
    }

    private func restoreSyncStatus() {
        guard let remote, remote.connection == connection, let first = remote.issueMessages.first else { return }
        syncIssue = true
        syncStatusMessage = "部分同步 · \(remote.issueMessages.count.formatted()) 个分片待处理 · \(first)"
    }

    private static func validFactor(_ value: Double) -> Bool { value.isFinite && value > 0 && value <= 100 }

    private var engine: PricingEngine {
        .init(book: priceSource == .omc ? omcPrices : publicPrices,
              fastMultiplier: fastMultiplier, ultraFastMultiplier: ultraFastMultiplier,
              fastMultipliersByChannel: fastMultipliersByChannel)
    }

    func formatDate(_ date: Date, as style: Date.FormatStyle) -> String {
        UsageDisplayTime.format(date, as: style.locale(Locale(identifier: "zh_Hans_CN")), calendar: displayCalendar)
    }

    func formatRelativeDate(_ date: Date) -> String {
        var style = Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "zh_Hans_CN"))
        style.calendar = displayCalendar
        return style.format(date)
    }

    private func resetDisplayClock() {
        displayClockRevision &+= 1
        let calendar = displayCalendar
        let now = Date.now
        lastClockDay = calendar.startOfDay(for: now)
        lastClockZone = calendar.timeZone.identifier
        lastDashboardMinute = Int(now.timeIntervalSince1970 / 60)
        if range == .custom {
            let start = UsageBucketInterval.hour.interval(containing: customHours.lowerBound, calendar: calendar)?.start ?? customHours.lowerBound
            let end = UsageBucketInterval.hour.interval(containing: customHours.upperBound, calendar: calendar)?.start ?? customHours.upperBound
            customHours = min(start, end)...max(start, end)
        } else {
            customHours = UsageDisplayTime.defaultHours(now: now, calendar: calendar)
        }
        resetQuickLook()
        rebuild()
        rebuildQuickLook()
    }

    private func refreshClockBoundary() {
        let calendar = displayCalendar
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let zone = calendar.timeZone.identifier
        let minute = Int(now.timeIntervalSince1970 / 60)
        let advanced = lastDashboardMinute != minute
        lastDashboardMinute = minute
        if let boundary = subscriptionNextBoundary, now >= boundary {
            subscriptionNextBoundary = nil
            subscriptionInputsChanged()
        }
        if let lastClockZone, lastClockZone != zone {
            resetDisplayClock()
        } else if today != lastClockDay {
            lastClockDay = today
            lastClockZone = zone
            if range != .custom { customHours = UsageDisplayTime.defaultHours(now: now, calendar: calendar) }
            rebuild()
            rebuildQuickLook()
        } else {
            if advanced && range != .all && range != .custom { rebuild() }
            if let nextQuickBoundary, now > nextQuickBoundary {
                self.nextQuickBoundary = nil
                rebuildQuickLook()
            }
        }
    }

    private func pricingChanged() {
        pricingRevision &+= 1
        cancelSubscriptionUsage()
        updateAvailable()
    }

    private func updateAvailable() {
        let selectedRemote = remote.flatMap { $0.connection == connection ? $0 : nil }
        lastSync = selectedRemote?.date
        var names = imported.deviceNames.merging(selectedRemote?.deviceNames ?? [:]) { _, synced in synced }
        names[thisDeviceID] = deviceName
        if names != deviceNames { deviceNames = names }

        dataUpdatePending = true
        startDataUpdate()
    }

    /// One expensive index build at a time. A collection or sync that arrives
    /// during this build requests a follow-up using the newest inputs.
    private func startDataUpdate() {
        guard ready, dataUpdatePending, dataTask == nil else { return }
        dataUpdatePending = false
        let selectedRemote = remote.flatMap { $0.connection == connection ? $0 : nil }
        let peer = selectedRemote?.cachedShards
        let inputs = [imported.requests] + (peer?.requestBatches ?? [selectedRemote?.legacyRequests ?? []]) + [localRequests]
        let localID = thisDeviceID
        let selectedConnection = connection
        let superseded = supersededRequestIDs
        let prices = engine
        let revision = pricingRevision
        let canReusePrices = indexedPricingRevision == revision
        let previousRows = canReusePrices ? allRequests : []
        let previousCosts = canReusePrices ? costsByRequest : [:]
        let previousSlots = modelColorSlots
        let previousPeer = subscriptionPeerObservations
        let names = deviceNames
        dataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                dataTask = nil
                if dataUpdatePending { startDataUpdate() }
                else if subscriptionUsageTask == nil && indexedPricingRevision != pricingRevision {
                    isSubscriptionUsageEstimating = false
                }
            }
            do {
                let (rows, costs, slots, observations, requestsChanged, quotaChanged) = try await Self.background {
                    let rows = try Self.merged(inputs, ownDevice: localID, superseded: superseded)
                    let observed = peer?.quotaObservations ?? []
                    try Task.checkCancellation()
                    let quotaChanged = observed != previousPeer
                    if canReusePrices, rows == previousRows, rows.count == previousCosts.count {
                        return (previousRows, previousCosts, previousSlots, observed, false, quotaChanged)
                    }
                    var previousIndex = previousRows.startIndex
                    var costs: [UsageKey: RequestCost] = [:]
                    var models: Set<String> = []
                    costs.reserveCapacity(rows.count)
                    for (index, row) in rows.enumerated() {
                        if index % 512 == 0 { try Task.checkCancellation() }
                        while previousIndex < previousRows.endIndex, Self.requestPrecedes(previousRows[previousIndex], row) {
                            previousIndex += 1
                        }
                        if previousIndex < previousRows.endIndex, previousRows[previousIndex] == row,
                           let value = previousCosts[row.key] {
                            costs[row.key] = value
                        } else {
                            costs[row.key] = prices.cost(row)
                        }
                        if previousSlots[row.modelIdentity] == nil { models.insert(row.modelIdentity) }
                    }
                    return (rows, costs, ModelColorSlots.adding(models, to: previousSlots), observed, true, quotaChanged)
                }
                guard !Task.isCancelled, connection == selectedConnection, pricingRevision == revision else { return }
                let needsRefresh = requestsChanged || indexedPricingRevision != revision
                    || subscriptionIndexedConnection != selectedConnection || indexedDeviceNames != names
                if requestsChanged {
                    dashboardWindowFacets = nil
                    allRequests = rows
                    costsByRequest = costs
                }
                indexedPricingRevision = revision
                indexedDeviceNames = names
                subscriptionIndexedConnection = selectedConnection
                if quotaChanged { subscriptionPeerObservations = observations }
                if modelColorSlots != slots {
                    modelColorSlots = slots
                    defaults.set(slots, forKey: "modelChartColorSlots")
                }
                if needsRefresh || quotaChanged { subscriptionInputsChanged() }
                if needsRefresh {
                    rebuild()
                    rebuildQuickLook()
                } else if quotaChanged, !subscriptionUsageVisible {
                    rebuildQuotaDepletion()
                }
            } catch { return }
        }
    }

    private func updateModelNameLabels() {
        let groups = Dictionary(grouping: models, by: { modelDisplayName($0).lowercased() })
        var duplicates: [String: String] = [:]
        for ids in groups.values where ids.count > 1 {
            for id in ids { duplicates[id] = "\(modelDisplayName(id)) · \(id)" }
        }
        modelNameOverrides = duplicates
    }

    private struct RollingQuickMetrics: Sendable {
        let metrics: UsageMetrics
        let groups: [QuickUsageDimension: [QuickUsageRow]]
        let models: [String: UsageMetrics]
    }

    private struct RollingQuickAccumulator {
        var metrics = UsageMetrics()
        var groups = QuickUsageGroups()
        var models: [String: UsageMetrics] = [:]

        mutating func add(_ row: UsageRequest, cost: RequestCost, title: String?) {
            metrics.add(row, cost: cost)
            models[row.modelIdentity, default: .init()].add(row, cost: cost)
            if row.totalTokens > 0 { groups.add(row, tokens: row.totalTokens, title: title) }
        }

        var snapshot: RollingQuickMetrics { .init(metrics: metrics, groups: groups.sorted, models: models) }
    }

    private struct QuickSnapshot: Sendable {
        let menuTrend: [QuickUsageScope: [Int64]]
        let cells: [UsageMiniTrendWindow.Cell]
        let bins: [QuickUsageScope: [Date: RollingQuickMetrics]]
        let rolling: [QuickUsageScope: RollingQuickMetrics]
        let nextRollingChange: Date?
    }

    private func rebuildQuickLook() {
        quickLookTask?.cancel()
        let rows = allRequests
        let titles = sessionTitles
        let calendar = displayCalendar
        let now = Date.now
        let localID = thisDeviceID
        let prices = engine
        let costs = indexedPricingRevision == pricingRevision ? costsByRequest : [:]
        quickLookTask = Task { [weak self] in
            do {
                let result = try await Self.background {
                    try Self.makeQuickSnapshot(rows: rows, titles: titles, localID: localID, calendar: calendar,
                                               now: now, costs: costs, prices: prices)
                }
                guard let self, !Task.isCancelled else { return }
                menuTrendByScope = result.menuTrend
                quickCells = result.cells
                quickBinsByScope = result.bins
                quickRolling = result.rolling
                nextQuickBoundary = result.nextRollingChange
                if let quickSelectedBinID, !result.cells.contains(where: { $0.id == quickSelectedBinID }) {
                    self.quickSelectedBinID = nil
                }
            } catch { return }
        }
    }

    private nonisolated static func makeQuickSnapshot(
        rows: [UsageRequest], titles: [String: String], localID: String,
        calendar: Calendar, now: Date, costs: [UsageKey: RequestCost], prices: PricingEngine
    ) throws -> QuickSnapshot {
        let menu = UsageMenuTrend(now: now)
        var trendAll = Array(repeating: Int64(0), count: UsageMenuTrend.count)
        var trendLocal = trendAll
        func accumulate(_ previous: Int64, _ value: Int64) -> Int64 {
            let (sum, overflow) = previous.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
        var rollingAll = RollingQuickAccumulator()
        var rollingLocal = RollingQuickAccumulator()
        var binsAll: [Date: RollingQuickAccumulator] = [:]
        var binsLocal: [Date: RollingQuickAccumulator] = [:]
        let miniTrend = UsageMiniTrendWindow(now: now, calendar: calendar)
        var nextRollingChange = miniTrend.nextGridChange
        func considerChange(_ date: Date) {
            nextRollingChange = min(nextRollingChange ?? date, date)
        }
        // The ledger is newest first, so stop at the shared 24-hour cutoff.
        for (index, row) in rows.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            if row.timestamp < menu.bounds.lowerBound { break }
            guard let menuIndex = menu.index(of: row.timestamp) else {
                considerChange(row.timestamp)
                continue
            }
            let localRequest = row.deviceID == localID
            trendAll[menuIndex] = accumulate(trendAll[menuIndex], row.totalTokens)
            if localRequest { trendLocal[menuIndex] = accumulate(trendLocal[menuIndex], row.totalTokens) }
            considerChange(menu.nextChange(for: row.timestamp, index: menuIndex))
            if let index = miniTrend.cellIndex(containing: row.timestamp) {
                let cost = costs[row.key] ?? prices.cost(row)
                let title = titles[row.sessionKey]
                let key = miniTrend.cells[index].id
                rollingAll.add(row, cost: cost, title: title)
                binsAll[key, default: .init()].add(row, cost: cost, title: title)
                if localRequest {
                    rollingLocal.add(row, cost: cost, title: title)
                    binsLocal[key, default: .init()].add(row, cost: cost, title: title)
                }
            }
        }
        return .init(menuTrend: [.all: trendAll, .local: trendLocal], cells: miniTrend.cells, bins: [.all: binsAll.mapValues(\.snapshot), .local: binsLocal.mapValues(\.snapshot)],
                     rolling: [.all: rollingAll.snapshot, .local: rollingLocal.snapshot],
                     nextRollingChange: nextRollingChange)
    }

    /// Filters and chart resolution don't change the facets for the selected
    /// time window. Keep only its small facet sets, not a second set of rows.
    private struct DashboardWindowFacets: Sendable {
        let indices: Range<Int>
        let facets: UsageWindow.Facets
    }

    private struct DashboardSnapshot: Sendable {
        let window: DashboardWindowFacets
        let rows: [UsageRequest]
        let unpricedRows: [UsageRequest]
        let metrics: UsageSnapshot
        let chartSeriesData: ChartSeriesData
        let models: [String]
        let devices: [String]
        let agents: [UsageAgentGroup]
        let tiers: [ServiceTier]
        let statuses: [RequestStatusFacet]
        let accounts: [UsageAccountFacet]
    }

    func setDashboardWindowVisible(_ visible: Bool) {
        guard dashboardWindowVisible != visible else { return }
        dashboardWindowVisible = visible
        if visible {
            if subscriptionUsageVisible { rebuildSubscriptionUsage() }
            else { rebuild() }
        } else {
            dashboardTask?.cancel()
            quotaDepletionTask?.cancel()
            quotaDepletionChartTask?.cancel()
            isQuotaDepletionChartLoading = false
            cancelSubscriptionUsage(keepCompleted: true)
        }
    }

    /// Closing the window releases the last dashboard generation. Hiding or
    /// minimizing only pauses work so the existing window can resume in place.
    func releaseClosedDashboard() {
        setDashboardWindowVisible(false)
        dashboardTask?.cancel()
        dashboardTask = nil
        dashboardWindowFacets = nil
        dashboardUpdatePending = true
        filteredRequests = []
        unpricedDashboardRequests = []
        snapshot = nil
        chartSeriesData = .empty
        quotaDepletionTask?.cancel()
        quotaDepletionTask = nil
        quotaDepletionChartTask?.cancel()
        quotaDepletionChartTask = nil
        quotaDepletionChartID = nil
        quotaDepletionChart = nil
        isQuotaDepletionChartLoading = false
        subscriptionUsageVisible = false
        cancelSubscriptionUsage()
        subscriptionUsageSnapshot = nil
        // Keep the small account option list so a saved selection is not
        // treated as missing before the first refreshed result on reopen.
    }

    private func rebuild() {
        guard ready, !rebuildingDashboard else { return }
        guard dashboardWindowVisible, !subscriptionUsageVisible else {
            dashboardUpdatePending = true
            return
        }
        dashboardUpdatePending = false
        dashboardTask?.cancel()
        let filters = self.filters
        let recentDimensions = chartGroupingRecency
        let groupingOverride = chartGroupingOverride
        let rows = allRequests, names = deviceNames
        let cachedWindow = dashboardWindowFacets
        let selectedRange = range, hours = customHours
        let calendar = displayCalendar
        let bounds = selectedRange.bounds(now: .now, customStart: hours.lowerBound, customEnd: hours.upperBound, calendar: calendar)
        rebuildQuotaDepletion(bounds: bounds)
        let target = chartTargetBucketCount
        let prices = engine
        let costs = indexedPricingRevision == pricingRevision ? costsByRequest : [:]
        dashboardTask = Task { [weak self] in
            do {
                let result = try await Self.background {
                    try Self.makeDashboard(rows: rows, cachedWindow: cachedWindow,
                                           names: names, selection: filters, range: selectedRange,
                                           bounds: bounds, calendar: calendar, prices: prices, costs: costs,
                                           targetBucketCount: target, recentDimensions: recentDimensions,
                                           groupingOverride: groupingOverride)
                }
                guard let self, !Task.isCancelled else { return }
                rebuildingDashboard = true
                defer { rebuildingDashboard = false }
                dashboardWindowFacets = result.window
                if models != result.models {
                    models = result.models
                    updateModelNameLabels()
                }
                if devices != result.devices { devices = result.devices }
                if agents != result.agents { agents = result.agents }
                if requestTiers != result.tiers { requestTiers = result.tiers }
                if requestStatuses != result.statuses { requestStatuses = result.statuses }
                if requestAccounts != result.accounts {
                    requestAccountNames = [:]
                    for (label, duplicates) in Dictionary(grouping: result.accounts, by: \.label) where duplicates.count > 1 {
                        for (index, account) in duplicates.enumerated() {
                            requestAccountNames[account] = "\(label) · \(index + 1)"
                        }
                    }
                    requestAccounts = result.accounts
                }
                filteredRequests = result.rows
                unpricedDashboardRequests = result.unpricedRows
                rememberChartColors(result.chartSeriesData)
                chartSeriesData = result.chartSeriesData
                snapshot = result.metrics
            } catch { return }
        }
    }

    private func rebuildQuotaDepletion(bounds selectedBounds: Range<Date>? = nil) {
        guard ready, dashboardWindowVisible else { return }
        quotaDepletionTask?.cancel()
        let bounds = selectedBounds ?? range.bounds(now: .now, customStart: customHours.lowerBound,
                                                    customEnd: customHours.upperBound, calendar: displayCalendar)
        let peerSamples = remote.flatMap { $0.connection == connection ? $0.cachedShards : nil }?.quotaObservations ?? []
        let native = nativeQuotaArchive
        // allRequests is the merged ledger in descending timestamp order.
        let historyStart = allRequests.last?.timestamp
        quotaDepletionTask = Task { [weak self] in
            do {
                let options = try await Self.background {
                    try Task.checkCancellation()
                    return QuotaDepletion.options(observations: native + peerSamples, bounds: bounds, historyStart: historyStart)
                }
                guard let self, !Task.isCancelled else { return }
                if quotaDepletionOptions != options { quotaDepletionOptions = options }
            } catch { return }
        }
        if quotaDepletionChartID != nil { refreshQuotaDepletionChart(bounds: bounds) }
    }

    func setQuotaDepletionChartSeries(_ id: String?) {
        guard quotaDepletionChartID != id else { return }
        quotaDepletionChartID = id
        quotaDepletionChartTask?.cancel()
        quotaDepletionChart = nil
        isQuotaDepletionChartLoading = false
        if id != nil { refreshQuotaDepletionChart() }
    }

    func refreshQuotaDepletionChart(bounds selectedBounds: Range<Date>? = nil) {
        guard ready, dashboardWindowVisible, let id = quotaDepletionChartID else { return }
        let calendar = displayCalendar
        let now = Date.now
        let requested = selectedBounds ?? range.bounds(now: now, customStart: customHours.lowerBound,
                                                       customEnd: customHours.upperBound, calendar: calendar)
        let peer = remote.flatMap { $0.connection == connection ? $0.cachedShards : nil }?.quotaObservations ?? []
        let readings = nativeQuotaArchive + peer + NativeQuotaHistoryStore.liveSamples(quotaAccounts)
        let rows = allRequests, names = deviceNames, price = engine
        let bounds: Range<Date>
        if range == .all {
            let first = [rows.last?.timestamp, readings.map(\.observedAt).min()].compactMap { $0 }.min() ?? now
            bounds = min(first, now.addingTimeInterval(-1))..<now
        } else {
            bounds = requested
        }
        let costs = indexedPricingRevision == pricingRevision ? costsByRequest : [:]
        let interval = timelineInterval
        quotaDepletionChartTask?.cancel()
        if quotaDepletionChart?.seriesID != id { quotaDepletionChart = nil }
        isQuotaDepletionChartLoading = true
        quotaDepletionChartTask = Task { [weak self] in
            do {
                let chart = try await Self.background {
                    try Task.checkCancellation()
                    return QuotaDepletionChart.build(seriesID: id, observations: readings, requests: rows,
                                                     pricing: price, deviceNames: names, costs: costs, bounds: bounds,
                                                     interval: interval, calendar: calendar)
                }
                guard let self, !Task.isCancelled, quotaDepletionChartID == id else { return }
                quotaDepletionChart = chart
                isQuotaDepletionChartLoading = false
            } catch { return }
        }
    }

    func setSubscriptionUsageVisible(_ visible: Bool) {
        guard subscriptionUsageVisible != visible else { return }
        subscriptionUsageVisible = visible
        if visible {
            dashboardTask?.cancel()
            dashboardUpdatePending = true
            rebuildSubscriptionUsage()
        } else {
            cancelSubscriptionUsage(keepCompleted: true)
            if dashboardUpdatePending { rebuild() }
        }
    }

    private struct SubscriptionUsageKey: Equatable {
        let revision: Int
    }

    private func subscriptionInputsChanged() {
        subscriptionInputsRevision &+= 1
        rebuildSubscriptionUsage()
    }

    private func cancelSubscriptionUsage(keepCompleted: Bool = false) {
        subscriptionUsageTask?.cancel()
        subscriptionUsageTask = nil
        subscriptionWorkID = nil
        subscriptionRunningKey = nil
        subscriptionQueuedKey = nil
        if !keepCompleted {
            subscriptionCompletedKey = nil
            subscriptionNextBoundary = nil
        }
        isSubscriptionUsageEstimating = false
    }

    private func rebuildSubscriptionUsage(now: Date = .now) {
        guard dashboardWindowVisible, subscriptionUsageVisible else { return }
        guard ready, indexedPricingRevision == pricingRevision,
              subscriptionIndexedConnection == connection else {
            isSubscriptionUsageEstimating = subscriptionUsageSnapshot == nil && (!ready || dataTask != nil)
            return
        }

        let at = now
        let key = SubscriptionUsageKey(revision: subscriptionInputsRevision)
        if subscriptionUsageTask != nil {
            subscriptionQueuedKey = key == subscriptionRunningKey ? nil : key
            return
        }
        guard key != subscriptionCompletedKey else { return }
        let work = UUID()
        subscriptionWorkID = work
        subscriptionRunningKey = key
        isSubscriptionUsageEstimating = subscriptionUsageSnapshot == nil
        let rows = allRequests, names = deviceNames, costs = costsByRequest
        let source = priceSource, prices = engine
        let history = nativeQuotaArchive, peer = subscriptionPeerObservations
        let live = NativeQuotaHistoryStore.liveSamples(quotaAccounts)
        subscriptionUsageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if subscriptionWorkID == work {
                    subscriptionUsageTask = nil
                    subscriptionRunningKey = nil
                    subscriptionWorkID = nil
                    isSubscriptionUsageEstimating = false
                    if subscriptionQueuedKey != nil {
                        subscriptionQueuedKey = nil
                        rebuildSubscriptionUsage()
                    }
                }
            }
            do {
                let windows = try await Self.background {
                    try Task.checkCancellation()
                    return UsageQuotaInsights.evaluate(observations: history + peer + live,
                                                       requests: rows, pricing: prices, deviceNames: names, costs: costs, at: at)
                }
                guard !Task.isCancelled, subscriptionWorkID == work else { return }
                subscriptionUsageSnapshot = .init(at: at, source: source, windows: windows)
                subscriptionCompletedKey = key
                subscriptionNextBoundary = windows.lazy
                    .flatMap { [$0.resetsAt, $0.observedAt.addingTimeInterval(7200.001)].compactMap { $0 } }
                    .filter { $0 > at }.min()
            } catch { return }
        }
    }

    private nonisolated static func makeDashboard(
        rows: [UsageRequest], cachedWindow: DashboardWindowFacets?,
        names: [String: String], selection: DashboardFilterSelection,
        range: UsageRange, bounds: Range<Date>, calendar: Calendar, prices: PricingEngine,
        costs: [UsageKey: RequestCost], targetBucketCount: Int,
        recentDimensions: [UsageChartDimension], groupingOverride: UsageChartDimension?
    ) throws -> DashboardSnapshot {
        try Task.checkCancellation()
        let indices = UsageWindow.indices(sortedNewestFirst: rows, bounds: bounds)
        let dated = rows[indices]
        let window = cachedWindow.flatMap { $0.indices == indices ? $0 : nil }
            ?? DashboardWindowFacets(indices: indices, facets: .init(requests: dated))
        let facets = window.facets
        // Keep checked values visible when a time-range change leaves no
        // matching records. Do not silently broaden the selected filters.
        let models = facets.models.union(selection.models).sorted()
        let devices = facets.devices.union(selection.devices).sorted {
            let lhs = names[$0] ?? $0, rhs = names[$1] ?? $1
            return lhs == rhs ? $0 < $1 : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let agents = UsageAgentGroup.allCases.filter { facets.agents.contains($0) || selection.agents.contains($0) }
        let tiers = ServiceTier.allCases.filter { facets.tiers.contains($0) || selection.tiers.contains($0) }
        let statuses = facets.statuses.union(selection.statuses).sorted()
        let accounts = facets.accounts.union(selection.accounts).sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        try Task.checkCancellation()
        var accountResolver = UsageAccountFacet.Resolver()
        let filtered: [UsageRequest]
        if selection.isEmpty {
            filtered = indices == rows.indices ? rows : Array(dated)
        } else {
            filtered = dated.filter { selection.includes($0, accountResolver: &accountResolver) }
        }
        let multiSelected = Set([
            (.model, selection.models.count), (.device, selection.devices.count), (.account, selection.accounts.count),
            (.agent, selection.agents.count), (.requestedTier, selection.tiers.count), (.status, selection.statuses.count),
        ].compactMap { (dimension: UsageChartDimension, count: Int) in count > 1 ? dimension : nil })
        let grouping = groupingOverride ?? UsageChartDimension.automatic(
            recentDimensions: recentDimensions, multiSelected: multiSelected, visibleRows: filtered
        )
        let history = range == .all ? dated.last.flatMap { oldest in
            dated.first.map { oldest.timestamp...$0.timestamp }
        } : nil
        try Task.checkCancellation()
        let metrics = UsageSnapshot(requests: filtered, range: range, bounds: bounds, calendar: calendar,
                                    prices: prices, allTimeSpan: history, precomputedCosts: costs,
                                    targetBucketCount: targetBucketCount, chartGrouping: grouping)
        let chartSeriesData = ChartSeriesData(timeline: metrics.timeline, series: metrics.seriesTimeline, grouping: grouping)
        // Build this once with the same price results as the KPI, not on each chart hover.
        let unpriced = metrics.metrics.unpricedRequests == 0 ? [] : filtered.filter { metrics.costs[$0.key] == .unknown }
        return .init(window: window, rows: filtered, unpricedRows: unpriced, metrics: metrics, chartSeriesData: chartSeriesData, models: models, devices: devices,
                     agents: agents, tiers: tiers, statuses: statuses, accounts: accounts)
    }

    private nonisolated static func applyingConfirmedAccounts(
        _ policy: ConfirmedNativeAccounts?, to rows: [UsageRequest]
    ) -> (rows: [UsageRequest], changed: Bool) {
        guard let policy else { return (rows, false) }
        var result = rows
        var changed = false
        for index in rows.indices where rows[index].accountEvidence == nil
            && (rows[index].account?.allSatisfy(\.isWhitespace) ?? true) {
            let attributed = policy.applying(to: rows[index])
            if attributed.accountEvidence == .userConfirmed {
                result[index] = attributed
                changed = true
            }
        }
        return (result, changed)
    }

    private nonisolated static func requestPrecedes(_ lhs: UsageRequest, _ rhs: UsageRequest) -> Bool {
        (lhs.timestamp, lhs.deviceID, lhs.id) > (rhs.timestamp, rhs.deviceID, rhs.id)
    }

    private nonisolated static func merged(
        _ inputs: [[UsageRequest]], ownDevice: String? = nil, superseded: Set<String> = []
    ) throws -> [UsageRequest] {
        var requests: [UsageKey: UsageRequest] = [:]
        for rows in inputs {
            for (index, candidate) in rows.enumerated() {
                if index.isMultiple(of: 1024) { try Task.checkCancellation() }
                guard candidate.isValid else { continue }
                var row = candidate
                row.deviceID = row.deviceID.lowercased()
                if row.deviceID == ownDevice && superseded.contains(row.id) { continue }
                if let previous = requests[row.key] { row = row.preservingEvidence(from: previous) }
                requests[row.key] = row
            }
        }
        try Task.checkCancellation()
        return requests.values.sorted(by: Self.requestPrecedes)
    }

    private nonisolated static func background<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func chooseJSON(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func readFile(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }
}

private struct DAVConnection: Codable, Equatable, Sendable {
    let url: URL
    let username: String
}

private struct RemoteLedgerStatus: Codable, Sendable {
    let checkpoint: UUID
    let date: Date?
    let issues: [String]
}

private struct RemoteLedger: Codable, Sendable {
    let connection: DAVConnection
    /// Only pre-shard caches need an extra flat array.
    let legacyRequests: [UsageRequest]
    let deviceNames: [String: String]
    let date: Date?
    let cachedShards: WebDAVShardCache?
    let issueMessages: [String]
    let checkpoint: UUID?

    private enum CodingKeys: String, CodingKey {
        case connection, requests, deviceNames, date, cachedShards, issueMessages, checkpoint
    }

    init(connection: DAVConnection, legacyRequests: [UsageRequest], deviceNames: [String: String], date: Date?,
         cachedShards: WebDAVShardCache?, issueMessages: [String], checkpoint: UUID?) {
        self.connection = connection
        self.legacyRequests = legacyRequests
        self.deviceNames = deviceNames
        self.date = date
        self.cachedShards = cachedShards
        self.issueMessages = issueMessages
        self.checkpoint = checkpoint
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        connection = try box.decode(DAVConnection.self, forKey: .connection)
        deviceNames = try box.decode([String: String].self, forKey: .deviceNames)
        date = try box.decodeIfPresent(Date.self, forKey: .date)
        issueMessages = try box.decodeIfPresent([String].self, forKey: .issueMessages) ?? []
        checkpoint = try box.decodeIfPresent(UUID.self, forKey: .checkpoint)
        cachedShards = try? box.decode(WebDAVShardCache.self, forKey: .cachedShards)
        legacyRequests = if cachedShards != nil { [] }
            else { try box.decode([UsageRequest].self, forKey: .requests) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(connection, forKey: .connection)
        try box.encode(deviceNames, forKey: .deviceNames)
        try box.encodeIfPresent(date, forKey: .date)
        try box.encodeIfPresent(checkpoint, forKey: .checkpoint)
        if !issueMessages.isEmpty { try box.encode(issueMessages, forKey: .issueMessages) }
        if let cachedShards { try box.encode(cachedShards, forKey: .cachedShards) }
        else { try box.encode(legacyRequests, forKey: .requests) }
    }

    func applying(_ status: RemoteLedgerStatus?) -> Self {
        guard let status, status.checkpoint == checkpoint else { return self }
        return .init(connection: connection, legacyRequests: legacyRequests, deviceNames: deviceNames, date: status.date,
                     cachedShards: cachedShards, issueMessages: status.issues, checkpoint: checkpoint)
    }

    private struct Header: Encodable {
        let connection: DAVConnection
        let deviceNames: [String: String]
        let date: Date?
        let checkpoint: UUID?
        let issueMessages: [String]?
    }

    static func readJSON(_ data: Data) throws -> Self {
        try Task.checkCancellation()
        let members = try JSONMemberSlices.members(in: data)
        let decoder = LedgerCodec.decoder()
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T {
            guard let range = members[key.rawValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: [], debugDescription: "Missing remote ledger member"))
            }
            return try decoder.decode(type, from: JSONMemberSlices.slice(in: data, range: range))
        }
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            guard members[key.rawValue] != nil else { return nil }
            return try read(Optional<T>.self, key)
        }
        let connection = try read(DAVConnection.self, .connection)
        let deviceNames = try read([String: String].self, .deviceNames)
        let date = try optional(Date.self, .date)
        let checkpoint = try optional(UUID.self, .checkpoint)
        let issueMessages = try optional([String].self, .issueMessages) ?? []
        let cachedShards: WebDAVShardCache?
        if let range = members[CodingKeys.cachedShards.rawValue] {
            do {
                cachedShards = try WebDAVShardCache.readJSON(data, range: range, decoder: decoder)
            } catch is DecodingError where members[CodingKeys.requests.rawValue] != nil {
                // Only fall back when a legacy ledger is actually present.
                cachedShards = nil
            }
        } else {
            cachedShards = nil
        }
        try Task.checkCancellation()
        let legacyRequests = cachedShards == nil ? try read([UsageRequest].self, .requests) : []
        return .init(connection: connection, legacyRequests: legacyRequests, deviceNames: deviceNames,
                     date: date, cachedShards: cachedShards, issueMessages: issueMessages, checkpoint: checkpoint)
    }

    func writeJSON(to file: FileHandle) throws {
        let encoder = LedgerCodec.encoder()
        guard let cachedShards else {
            try file.write(contentsOf: encoder.encode(self))
            return
        }
        let header = Header(connection: connection, deviceNames: deviceNames, date: date, checkpoint: checkpoint,
                            issueMessages: issueMessages.isEmpty ? nil : issueMessages)
        try file.write(contentsOf: encoder.encode(header).dropLast())
        try file.write(contentsOf: Data(",\"cachedShards\":".utf8))
        try cachedShards.writeJSON(to: file)
        try file.write(contentsOf: Data("}".utf8))
    }
}

private struct LocalLedger: Codable, Sendable {
    let requests: [UsageRequest]
    let supersededRequestIDs: Set<String>
}

private struct PortableLedger: Codable, Sendable {
    let schemaVersion: Int
    let requests: [UsageRequest]
    var deviceNames: [String: String]? = nil
    var deviceID: String? = nil
    var deviceName: String? = nil
}

private struct ImportedLedger: Codable, Sendable {
    let requests: [UsageRequest]
    let deviceNames: [String: String]
}

private enum LedgerCodec {
    // Use the DAV formatter's UTC millisecond rounding. Truncating ISO strings
    // can shift a cached request into the prior monthly shard after restart.
    private static let wireDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    static func encoder() -> JSONEncoder {
        let codec = JSONEncoder()
        codec.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(wireDate.string(from: date))
        }
        codec.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return codec
    }

    static func decoder() -> JSONDecoder {
        let codec = JSONDecoder()
        codec.userInfo[UsageStringInterner.key] = UsageStringInterner()
        codec.dateDecodingStrategy = .custom {
            let container = try $0.singleValueContainer()
            let text = try container.decode(String.self)
            for fractional in [true, false] {
                if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: fractional).parse(text) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date")
        }
        return codec
    }

    static func decodePortable(_ data: Data) throws -> ImportedLedger {
        let ledger = try decoder().decode(PortableLedger.self, from: data)
        guard ledger.schemaVersion == 1, ledger.requests.allSatisfy({ $0.isValid && UUID(uuidString: $0.deviceID) != nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var names: [String: String] = [:]
        for (id, name) in ledger.deviceNames ?? [:] where UUID(uuidString: id) != nil && !name.isEmpty {
            names[id.lowercased()] = name
        }
        if let id = ledger.deviceID, UUID(uuidString: id) != nil, let name = ledger.deviceName, !name.isEmpty {
            names[id.lowercased()] = name
        }
        return .init(requests: ledger.requests, deviceNames: names)
    }
}

private actor LedgerStore {
    static let localFile = "local-v2.json"
    let directory: URL
    private var writeProtected: Set<String> = []
    init(directory: URL) { self.directory = directory }

    struct State: Sendable {
        let local: LocalLedger
        let imported: ImportedLedger
        let remote: RemoteLedger?
        let omc: PriceBook
        let publicCatalog: PriceBook
        let modelNames: ModelNames
        let modelNamesUpdated: Date?
        let issues: [String]
        let needsInitialReconciliation: Bool
    }

    func load() throws -> State {
        var issues: [String] = []
        let modern = try recover(LocalLedger.self, file: Self.localFile, issues: &issues)
        let damagedModern = modern == nil && !issues.isEmpty
        // After damage, an old pre-migration copy may contain already retired
        // keys with no tombstones. Keep that copy untouched and rebuild from
        // verifiable sources instead of silently publishing its stale rows.
        let legacy: [UsageRequest] = if modern == nil && !damagedModern {
            try recover([UsageRequest].self, file: "local.json", issues: &issues) ?? []
        } else { [] }
        let local = modern ?? LocalLedger(requests: legacy, supersededRequestIDs: [])
        let imported = try recover(ImportedLedger.self, file: "imports.json", issues: &issues)
            ?? .init(requests: [], deviceNames: [:])
        let remote = try recover(file: "remote.json", issues: &issues) { try loadRemote() }?
            .applying(try? load(RemoteLedgerStatus.self, file: "remote-status.json"))
        try Task.checkCancellation()
        let publicCatalog = loadBook("public-prices.json", as: .publicCatalog) ?? (try? PriceBook.bundledPublic()) ?? .empty
        let bundledNames = (try? ModelNames.bundled()) ?? .empty
        let cachedNamesURL = directory.appending(path: "model-names.json")
        let cachedNames = (try? Data(contentsOf: cachedNamesURL, options: .mappedIfSafe)).flatMap { try? ModelNames.decode($0) }
        let namesUpdated = cachedNames == nil ? nil : (try? cachedNamesURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return .init(local: local, imported: imported, remote: remote,
                     omc: loadBook("omc-prices.json", as: .omc) ?? .empty, publicCatalog: publicCatalog,
                     modelNames: cachedNames.map { bundledNames.merging($0) } ?? bundledNames,
                     modelNamesUpdated: namesUpdated, issues: issues,
                     needsInitialReconciliation: damagedModern || !legacy.isEmpty)
    }

    private func recover<T: Codable & Sendable>(_ type: T.Type, file: String, issues: inout [String]) throws -> T? {
        try recover(file: file, issues: &issues) { try load(type, file: file) }
    }

    private func recover<T>(file: String, issues: inout [String], read: () throws -> T?) throws -> T? {
        try Task.checkCancellation()
        do { return try read() }
        catch is CancellationError {
            throw CancellationError()
        } catch is DecodingError {
            try Task.checkCancellation()
            let original = directory.appending(path: file)
            let backupName = file + ".unreadable-" + UUID().uuidString
            do {
                try FileManager.default.moveItem(at: original, to: directory.appending(path: backupName))
                issues.append("\(file) 无法解码，原件已备份")
            } catch {
                writeProtected.insert(file)
                issues.append("\(file) 无法解码，原件保留且不覆盖")
            }
        } catch {
            try Task.checkCancellation()
            writeProtected.insert(file)
            issues.append("\(file) 暂不可读，原件保留且不覆盖")
        }
        return nil
    }

    func saveModelNames(_ names: ModelNames) throws -> Date {
        try saveData(names.encoded(), file: "model-names.json")
        return .now
    }

    private func load<T: Codable & Sendable>(_ type: T.Type, file: String) throws -> T? {
        guard let data = try storedData(file) else { return nil }
        let decoded = try LedgerCodec.decoder().decode(type, from: data)
        // Pre-release ledgers may contain titles that were generated from prompts.
        if data.range(of: Data("\"sessionTitle\"".utf8)) != nil {
            try save(decoded, file: file)
        }
        return decoded
    }

    private func loadRemote() throws -> RemoteLedger? {
        guard let data = try storedData("remote.json") else { return nil }
        let decoded = try RemoteLedger.readJSON(data)
        if data.range(of: Data("\"sessionTitle\"".utf8)) != nil {
            try saveRemote(decoded)
        }
        return decoded
    }

    private func storedData(_ file: String) throws -> Data? {
        let url = directory.appending(path: file)
        do { return try Data(contentsOf: url, options: .mappedIfSafe) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    }

    private func loadBook(_ file: String, as source: PriceSource) -> PriceBook? {
        guard let data = try? Data(contentsOf: directory.appending(path: file), options: .mappedIfSafe) else { return nil }
        return try? PriceBook.decode(data, as: source)
    }

    func save<T: Encodable & Sendable>(_ value: T, file: String) throws {
        try saveData(LedgerCodec.encoder().encode(value), file: file)
    }

    func saveRemote(_ value: RemoteLedger) throws {
        let filename = "remote.json"
        guard !writeProtected.contains(filename) else { throw CocoaError(.fileWriteNoPermission) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appending(path: ".remote-write-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try value.writeJSON(to: handle)
        try handle.synchronize()
        try handle.close()
        try Task.checkCancellation()
        let destination = directory.appending(path: filename)
        // Both files are on the same volume, so readers see either complete version.
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func saveData(_ data: Data, file: String) throws {
        guard !writeProtected.contains(file) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appending(path: file), options: .atomic)
    }
}
