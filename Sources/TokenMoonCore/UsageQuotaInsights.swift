// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// API-equivalent subscription amounts derived from official quota observations and
/// the synchronized request ledger. This calculation never changes provider readings.
public enum UsageQuotaInsights {
    public enum Provider: String, Sendable {
        case codex, claude, gemini

        public init?(agent: Agent) {
            switch agent {
            case .codex: self = .codex
            case .claudeCode, .claudeDesktop: self = .claude
            case .antigravity: self = .gemini
            case .cpa: return nil
            }
        }
    }

    public enum Quality: String, Sendable {
        case missingWindow = "missing_window"
        case zeroConsumption = "zero_consumption"
        case staleQuota = "stale_quota"
        case expiredWindow = "expired_window"
        case unpriced
        case inferredAccount = "inferred_account"
        case partialHistory = "partial_history"
    }

    public enum RecentStatus: String, Sendable {
        case ready, unpriced
        case insufficientHistory = "insufficient_history"
        case partialHistory = "partial_history"
    }

    public struct HistoryPoint: Identifiable, Equatable, Sendable {
        public let at: Date
        public let usedPercent: Double
        public var id: Date { at }
    }

    public struct DeviceContribution: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let requests: Int
        public let totalTokens: Int64
        public let knownCostUSD: Double?
        public let priceShare: Double?
        public let pricedRequests: Int
        public let unpricedRequests: Int
        public let excludedRequests: Int
    }

    public struct ModelCostShare: Identifiable, Equatable, Sendable {
        public let model: String
        /// Calculated cost in billionths of one US dollar.
        public let costNanos: Int64
        public var id: String { model }
    }

    public struct Cycle: Identifiable, Equatable, Sendable {
        public let id: String
        public let start: Date?
        public let resetsAt: Date?
        public let observedAt: Date
        public let usedPercent: Double
        public let observedCostUSD: Double?
        public let estimatedFullUSD: Double?
        public let requests: Int
        public let unpricedRequests: Int
        public let excludedRequests: Int
        public let unattributedRequests: Int
        public let coverageIncomplete: Bool
        public let devices: [DeviceContribution]
        /// Positive, observed API-equivalent costs grouped by model from the same attributed requests as `devices`.
        public let modelCosts: [ModelCostShare]
        public fileprivate(set) var isCurrent: Bool

        public var fullUncertaintyUSD: Double? {
            coverageIncomplete ? nil : estimateError(full: estimatedFullUSD, usedPercent: usedPercent)
        }
        public var eligibleRequests: Int { requests - excludedRequests }
        public var pricedRequests: Int { eligibleRequests - unpricedRequests }
        public var pricingCoverage: Double? {
            eligibleRequests > 0 ? Double(pricedRequests) / Double(eligibleRequests) : nil
        }
        public func feeShare(monthlyFee: Double?) -> Double? {
            UsageQuotaInsights.feeShare(monthlyFee: monthlyFee, start: start, resetsAt: resetsAt)
        }
        public func observedFeeRatio(monthlyFee: Double?) -> Double? {
            guard let share = feeShare(monthlyFee: monthlyFee), let observedCostUSD else { return nil }
            return observedCostUSD / share
        }
        public func fullFeeRatio(monthlyFee: Double?) -> Double? {
            guard let share = feeShare(monthlyFee: monthlyFee), let estimatedFullUSD else { return nil }
            return estimatedFullUSD / share
        }
    }

    public struct RecentUsage: Equatable, Sendable {
        public fileprivate(set) var status: RecentStatus = .insufficientHistory
        public fileprivate(set) var usedPercent: Double = 0
        public fileprivate(set) var costUSD: Double?
        public fileprivate(set) var observedCostUSD: Double?
        public fileprivate(set) var from: Date?
        public fileprivate(set) var to: Date?
        public fileprivate(set) var cycleCount: Int = 0
        public fileprivate(set) var boundaryProrated: Bool = false
        public fileprivate(set) var requests: Int = 0
        public fileprivate(set) var unpricedRequests: Int = 0
        public fileprivate(set) var excludedRequests: Int = 0
        /// The official percent can be confirmed independently of the cost coverage.
        public fileprivate(set) var coverageIncomplete: Bool = false
        public fileprivate(set) var unattributedRequests: Int = 0
    }

    public struct Window: Identifiable, Equatable, Sendable {
        public let id: String
        public let provider: Provider
        public let account: String
        public let windowID: String
        public let label: String
        public let currentCycle: Cycle
        public let isActive: Bool
        public let quality: [Quality]
        public let history: [HistoryPoint]
        /// Chronological by the observed start; periods lacking a start remain selectable at the end.
        public let cycles: [Cycle]
        public let recentUsage: RecentUsage

        public var feeKey: String { provider.rawValue + "/" + account }
        public var start: Date? { currentCycle.start }
        public var resetsAt: Date? { currentCycle.resetsAt }
        public var observedAt: Date { currentCycle.observedAt }
        public var usedPercent: Double { currentCycle.usedPercent }
        public var remainingPercent: Double { 100 - usedPercent }
        public var observedCostUSD: Double? { currentCycle.observedCostUSD }
        public var estimatedFullUSD: Double? { currentCycle.estimatedFullUSD }
        public var estimatedRemainingUSD: Double? { estimatedFullUSD.map { $0 * (remainingPercent / 100) } }
        public var fullUncertaintyUSD: Double? { currentCycle.fullUncertaintyUSD }
        public var remainingUncertaintyUSD: Double? { estimatedRemainingUSD == nil ? nil : fullUncertaintyUSD }
        public var requests: Int { currentCycle.requests }
        public var unpricedRequests: Int { currentCycle.unpricedRequests }
        public var excludedRequests: Int { currentCycle.excludedRequests }
        public var unattributedRequests: Int { currentCycle.unattributedRequests }
        /// Creator-only identities are deliberately excluded from attribution.
        public var inferredAccountRequests: Int { 0 }
        public var devices: [DeviceContribution] { currentCycle.devices }
        public var plottedCycles: [Cycle] { cycles.filter { $0.start != nil } }
    }

    public static func evaluate(
        observations: [QuotaWireObservation], requests: [UsageRequest], pricing: PricingEngine,
        deviceNames: [String: String] = [:], costs: [UsageKey: RequestCost] = [:], at: Date = .now
    ) -> [Window] {
        guard at.timeIntervalSinceReferenceDate.isFinite else { return [] }
        var readings: [AccountWindow: [Date: Reading]] = [:]
        var conflicts: [AccountWindow: Set<Date>] = [:]
        var identityCache = AccountIdentityCache()
        var firstWindowStart: Date?
        var lastWindowObservation: Date?
        for (index, sample) in observations.enumerated() {
            if index.isMultiple(of: 1024), Task.isCancelled { return [] }
            guard sample.observedAt <= at, sample.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  let provider = Provider(agent: sample.agent), case let .email(email) = identityCache.resolve(sample.account),
                  !sample.windowID.isEmpty, !sample.windowLabel.isEmpty,
                  sample.windowID.count <= 256, sample.windowLabel.count <= 256,
                  (0...100).contains(sample.usedPercent) else { continue }
            let key = AccountWindow(provider: provider, email: email, window: sample.windowID)
            let reading = Reading(sample)
            guard conflicts[key]?.contains(reading.at) != true else { continue }
            if let prior = readings[key]?[reading.at] {
                if prior.used != reading.used || prior.start != reading.start || prior.reset != reading.reset {
                    readings[key]?[reading.at] = nil
                    conflicts[key, default: []].insert(reading.at)
                }
            } else {
                readings[key, default: [:]][reading.at] = reading
                if reading.isValid, let start = reading.start {
                    firstWindowStart = min(firstWindowStart ?? start, start)
                    lastWindowObservation = max(lastWindowObservation ?? reading.at, reading.at)
                }
            }
        }
        guard !readings.isEmpty, var ledger = Ledger(requests: requests, pricing: pricing, deviceNames: deviceNames, costs: costs) else { return [] }
        if let firstWindowStart, let lastWindowObservation {
            ledger.prepareAccounts(Set(readings.keys.map(\.accountKey)), from: firstWindowStart,
                                   to: lastWindowObservation, identities: &identityCache)
        }
        guard !Task.isCancelled else { return [] }
        return readings.compactMap { key, byDate in
            guard !Task.isCancelled else { return nil }
            let points = byDate.values.sorted { $0.at < $1.at }
            return ledger.window(for: key, points: points, asOf: at)
        }.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.account != $1.account { return $0.account < $1.account }
            if $0.isActive != $1.isActive { return $0.isActive }
            return ($0.label, $0.windowID) < ($1.label, $1.windowID)
        }
    }

    /// Web Insights allows a local USD/month what-if and uses an average Gregorian month.
    public static func feeShare(monthlyFee: Double?, start: Date?, resetsAt: Date?) -> Double? {
        guard let monthlyFee, monthlyFee.isFinite, monthlyFee > 0,
              let start, let resetsAt, resetsAt > start else { return nil }
        let share = monthlyFee * (resetsAt.timeIntervalSince(start) / (30.4375 * 86_400))
        return share.isFinite && share > 0 ? share : nil
    }

    /// Full and remaining estimates carry the same USD error with observed cost held fixed.
    /// Infinity denotes that the one-percentage-point observation granularity has no finite upper bound.
    public static func estimateError(full: Double?, usedPercent: Double) -> Double? {
        guard let full, full.isFinite, full >= 0, (0...100).contains(usedPercent), usedPercent > 0 else { return nil }
        if full == 0 { return 0 }
        return usedPercent <= 1 ? .infinity : full / (usedPercent - 1)
    }
}

private extension UsageQuotaInsights {
    struct AccountKey: Hashable {
        let provider: Provider
        let email: String
    }

    struct AccountWindow: Hashable {
        let provider: Provider
        let email: String
        let window: String
        var accountKey: AccountKey { AccountKey(provider: provider, email: email) }
        var id: String { String(collectorID(provider.rawValue + "|" + email, window).prefix(20)) }
    }

    struct Reading {
        let at: Date
        let used: Double
        let start: Date?
        let reset: Date?
        let label: String

        init(_ sample: QuotaWireObservation) {
            at = sample.observedAt
            used = sample.usedPercent
            reset = sample.resetsAt.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
            if let reset, let duration = sample.durationSeconds, (0...366 * 86_400).contains(duration), duration > 0 {
                start = reset.addingTimeInterval(-duration)
            } else {
                start = nil
            }
            label = sample.windowLabel
        }

        var isValid: Bool {
            guard let start, let reset else { return false }
            return start < reset && start <= at && at < reset
        }
        var isUnusedPrediction: Bool {
            guard let start, let reset else { return false }
            return used == 0 && start < reset && at < start
        }
    }

    struct Interval {
        let from: Date
        let to: Date
        let used: Double
        let cycle: Int
        let includeFrom: Bool
    }

    static let address = try! NSRegularExpression(pattern: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    static let keyMask = try! NSRegularExpression(pattern: #"(?i)sk-[A-Za-z0-9_-]{1,32}(?:\*{3,}|•{3,}|…+)[A-Za-z0-9_-]{1,12}"#)

    static func email(_ value: String?) -> String? {
        guard let value = collectorText(value, limit: 254), value.contains("@") else { return nil }
        return matches(address, value) ? value.lowercased() : nil
    }

    static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range)?.range == range
    }

    enum AccountIdentity {
        case email(String), maskedKey, unknown
    }

    struct AccountIdentityCache {
        var values: [String: AccountIdentity] = [:]

        mutating func resolve(_ account: String?) -> AccountIdentity {
            guard let account, !account.isEmpty else { return .unknown }
            if let known = values[account] { return known }
            let identity: AccountIdentity
            if let email = UsageQuotaInsights.email(account) {
                identity = .email(email)
            } else if account.lowercased().hasPrefix("sk-"), matches(keyMask, account) {
                identity = .maskedKey
            } else {
                identity = .unknown
            }
            if values.count < 1024 { values[account] = identity }
            return identity
        }
    }

    struct Totals {
        var requests = 0
        var tokens: Int64 = 0
        var priced = 0
        var unpriced = 0
        var excluded = 0
        var nanos: Int64 = 0
        var overflowed = false

        mutating func add(_ cost: RequestCost, tokens: Int64) {
            requests += 1
            self.tokens = sumTokens(self.tokens, tokens)
            switch cost {
            case let .priced(value), let .pricedWithCacheWriteFallback(value):
                priced += 1
                let (total, overflow) = nanos.addingReportingOverflow(value)
                overflowed = overflowed || overflow
                if !overflowed { nanos = total }
            case .unknown: unpriced += 1
            case .excluded: excluded += 1
            }
        }

        var hasKnownContribution: Bool { !overflowed && (priced > 0 || (excluded > 0 && unpriced == 0)) }
        var knownCost: Double? { hasKnownContribution ? Double(nanos) / 1e9 : nil }
    }

    struct Ledger {
        let rows: [UsageRequest]
        let newestFirst: Bool
        let pricing: PricingEngine
        let names: [String: String]
        let cachedCosts: [UsageKey: RequestCost]
        var quotes: [Int: RequestCost] = [:]
        var accounts: [AccountKey: [Int]] = [:]
        var unattributed: [Provider: [Int]] = [:]
        var costModelKeys: [String: String] = [:]

        init?(requests: [UsageRequest], pricing: PricingEngine, deviceNames: [String: String], costs: [UsageKey: RequestCost]) {
            // AppModel already supplies newest-first rows. Use chronological
            // indices over that same array instead of copying full requests.
            let descending = requests.first.map { first in requests.last.map { $0.timestamp < first.timestamp } ?? false } ?? false
            var ordered = true
            var last: Date?
            for index in requests.indices {
                if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                let date = requests[index].timestamp
                if !date.timeIntervalSinceReferenceDate.isFinite
                    || (last.map { descending ? $0 < date : $0 > date } ?? false) {
                    ordered = false
                    break
                }
                last = date
            }
            if ordered {
                rows = requests
                newestFirst = descending
            } else {
                rows = requests.filter { $0.timestamp.timeIntervalSinceReferenceDate.isFinite }.sorted { $0.timestamp < $1.timestamp }
                newestFirst = false
            }
            guard !Task.isCancelled else { return nil }
            self.pricing = pricing
            names = Dictionary(deviceNames.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            cachedCosts = costs
        }

        var firstAt: Date? { (newestFirst ? rows.last : rows.first)?.timestamp }

        private func physicalIndex(_ chronological: Int) -> Int {
            newestFirst ? rows.count - 1 - chronological : chronological
        }

        mutating func prepareAccounts(_ keys: Set<AccountKey>, from: Date, to: Date, identities: inout AccountIdentityCache) {
            let providers = Set(keys.map(\.provider))
            for offset in range(from: from, to: to) {
                if offset.isMultiple(of: 1024), Task.isCancelled { return }
                let index = physicalIndex(offset)
                let row = rows[index]
                // Explicit API keys, masked keys and already-known other
                // accounts neither contribute nor create an attribution gap.
                if isExplicitAPIKeyLogin(row.loginMethod) { continue }
                let channel = row.channelIdentity.lowercased()
                let provider = channel == "gpt / codex" ? Provider.codex : Provider(rawValue: channel)
                switch identities.resolve(row.account) {
                case let .email(email):
                    if let provider {
                        let key = AccountKey(provider: provider, email: email)
                        if keys.contains(key) { accounts[key, default: []].append(index) }
                    }
                case .maskedKey:
                    break
                case .unknown:
                    // A session creator is separate from request ownership.
                    let model = row.modelIdentity
                    guard model != "codex-auto-review", !(row.isFailure && row.totalTokens == 0) else { continue }
                    if let provider, providers.contains(provider) { unattributed[provider, default: []].append(index) }
                    let group = row.agentGroup
                    if provider != .codex, group == .codex, providers.contains(.codex) {
                        unattributed[.codex, default: []].append(index)
                    }
                    if provider != .claude, model.hasPrefix("claude-"), providers.contains(.claude) {
                        unattributed[.claude, default: []].append(index)
                    }
                    if provider != .gemini, group == .antigravity, providers.contains(.gemini) {
                        unattributed[.gemini, default: []].append(index)
                    }
                }
            }
        }

        mutating func cost(_ index: Int) -> RequestCost {
            if let known = quotes[index] { return known }
            let row = rows[index]
            let result = cachedCosts[row.key] ?? pricing.cost(row)
            quotes[index] = result
            return result
        }

        func range(in indices: [Int]? = nil, from: Date, to: Date,
                   includeFrom: Bool = true, includeTo: Bool = true) -> Range<Int> {
            func bound(_ time: Date, strictlyAfter: Bool) -> Int {
                var lower = 0
                var upper = indices?.count ?? rows.count
                while lower < upper {
                    let mid = lower + (upper - lower) / 2
                    let date = rows[indices?[mid] ?? physicalIndex(mid)].timestamp
                    if date < time || (strictlyAfter && date == time) { lower = mid + 1 }
                    else { upper = mid }
                }
                return lower
            }
            let lower = bound(from, strictlyAfter: !includeFrom)
            let upper = bound(to, strictlyAfter: includeTo)
            return lower..<max(lower, upper)
        }

        func attributedRows(for key: AccountWindow, from: Date, to: Date,
                            includeFrom: Bool = true, includeTo: Bool = true) -> ArraySlice<Int> {
            let indices = accounts[key.accountKey] ?? []
            return indices[range(in: indices, from: from, to: to, includeFrom: includeFrom, includeTo: includeTo)]
        }

        func unattributedCount(for provider: Provider, from: Date, to: Date,
                               includeFrom: Bool = true, includeTo: Bool = true) -> Int {
            guard let indices = unattributed[provider] else { return 0 }
            return range(in: indices, from: from, to: to, includeFrom: includeFrom, includeTo: includeTo).count
        }

        private mutating func normalizedCostModel(_ identity: String) -> String {
            if let key = costModelKeys[identity] { return key }
            let name = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = switch name.lowercased() {
            case "", "unknown", "unknown-model", "<unknown>", "(unknown)", "未知模型", "synthetic", "<synthetic>", "—":
                ""
            default:
                name
            }
            costModelKeys[identity] = key
            return key
        }

        private mutating func costModelKey(for row: UsageRequest) -> String {
            // Prefer the served model, except placeholders never hide a known request model.
            if let sent = row.sentModel {
                let known = normalizedCostModel(sent)
                if !known.isEmpty { return known }
            }
            let requested = normalizedCostModel(row.requestedModel)
            return requested.isEmpty ? "unknown" : requested
        }

        mutating func priceCycle(_ point: Reading, key: AccountWindow, current: Bool) -> (Cycle, partial: Bool) {
            var totals = Totals()
            var byDevice: [String: Totals] = [:]
            var byModel: [String: Int64] = [:]
            var modelCostsComplete = true
            var unattributed = 0
            var partial = true
            if point.isValid, let start = point.start {
                unattributed = unattributedCount(for: key.provider, from: start, to: point.at)
                partial = unattributed > 0 || (firstAt.map { $0 > start } ?? false)
                for (offset, index) in attributedRows(for: key, from: start, to: point.at).enumerated() {
                    if offset.isMultiple(of: 1024), Task.isCancelled { partial = true; break }
                    let row = rows[index]
                    let amount = cost(index)
                    let tokens = row.totalTokens
                    totals.add(amount, tokens: tokens)
                    byDevice[row.deviceID.lowercased(), default: Totals()].add(amount, tokens: tokens)
                    switch amount {
                    case let .priced(nanos), let .pricedWithCacheWriteFallback(nanos):
                        // A negative price cannot be represented by the pie. For
                        // positive prices, checking the cycle total also bounds each slice.
                        if nanos < 0 { modelCostsComplete = false }
                        if nanos > 0, modelCostsComplete, !totals.overflowed {
                            let model = costModelKey(for: row)
                            byModel[model, default: 0] += nanos
                        }
                    case .unknown, .excluded:
                        break
                    }
                }
                partial = partial || totals.overflowed
            }
            let observed = point.isValid && (!partial || totals.priced > 0)
                ? (totals.requests == 0 ? 0 : totals.knownCost) : nil
            let full = observed.flatMap { value -> Double? in
                // An incomplete window can still show a reference from known
                // spend. It never assigns an unidentified request to this account.
                guard point.used > 0, totals.hasKnownContribution, !partial || totals.priced > 0 else { return nil }
                let estimate = value / (point.used / 100)
                return estimate.isFinite ? estimate : nil
            }
            let knownTotal = totals.knownCost ?? 0
            let devices = byDevice.map { id, amount in
                DeviceContribution(id: id, name: names[id] ?? id, requests: amount.requests,
                                   totalTokens: amount.tokens, knownCostUSD: amount.knownCost,
                                   priceShare: knownTotal > 0 ? amount.knownCost.map { $0 / knownTotal } : nil,
                                   pricedRequests: amount.priced, unpricedRequests: amount.unpriced,
                                   excludedRequests: amount.excluded)
            }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            var modelCosts: [ModelCostShare] = []
            if observed != nil, modelCostsComplete, !totals.overflowed {
                modelCosts = byModel.map { entry in
                    ModelCostShare(model: entry.key, costNanos: entry.value)
                }
                modelCosts.sort { left, right in
                    if left.costNanos != right.costNanos { return left.costNanos > right.costNanos }
                    return left.model < right.model
                }
            }
            return (Cycle(id: key.id + "/" + String(point.start?.timeIntervalSinceReferenceDate ?? point.at.timeIntervalSinceReferenceDate)
                          + "/" + String(point.reset?.timeIntervalSinceReferenceDate ?? point.at.timeIntervalSinceReferenceDate),
                          start: point.start, resetsAt: point.reset, observedAt: point.at, usedPercent: point.used,
                          observedCostUSD: observed, estimatedFullUSD: full, requests: totals.requests,
                          unpricedRequests: totals.unpriced, excludedRequests: totals.excluded,
                          unattributedRequests: unattributed, coverageIncomplete: partial,
                          devices: devices, modelCosts: modelCosts, isCurrent: current), partial)
        }

        mutating func window(for key: AccountWindow, points: [Reading], asOf: Date) -> Window? {
            guard let point = points.last else { return nil }
            let (current, partial) = priceCycle(point, key: key, current: true)
            let isActive = point.isValid && point.reset.map { asOf < $0 } == true
            var quality: [Quality] = []
            if !point.isValid { quality.append(.missingWindow) }
            if point.used == 0 { quality.append(.zeroConsumption) }
            if asOf.timeIntervalSince(point.at) > 2 * 3600 { quality.append(.staleQuota) }
            if point.isValid && !isActive { quality.append(.expiredWindow) }
            if current.unpricedRequests > 0 { quality.append(.unpriced) }
            if partial { quality.append(.partialHistory) }

            let groups = group(points)
            var cycles: [Cycle] = []
            for entry in groups.compactMap(\.last) {
                if Task.isCancelled { return nil }
                if entry.at == point.at {
                    cycles.append(current)
                } else {
                    cycles.append(priceCycle(entry, key: key, current: false).0)
                }
            }
            // The UI considers a reset prediction within one minute the same
            // current period. Missing starts stay available but are not plotted.
            if !cycles.contains(where: \.isCurrent) {
                if let index = cycles.indices.reversed().first(where: { near(cycles[$0], current) }) {
                    cycles[index].isCurrent = true
                } else if current.start != nil || current.resetsAt != nil {
                    cycles.append(current)
                }
            }
            cycles.sort {
                switch ($0.start, $1.start) {
                case let (left?, right?): return left == right ? $0.observedAt < $1.observedAt : left < right
                case (nil, nil): return $0.observedAt < $1.observedAt
                case (nil, _?): return false
                case (_?, nil): return true
                }
            }

            let recent = recentUsage(for: key, points: points, groups: groups)
            guard !Task.isCancelled else { return nil }
            return Window(id: key.id, provider: key.provider, account: key.email, windowID: key.window,
                          label: point.label, currentCycle: current, isActive: isActive, quality: quality,
                          history: points.map { HistoryPoint(at: $0.at, usedPercent: $0.used) },
                          cycles: cycles, recentUsage: recent)
        }

        private func near(_ candidate: Cycle, _ current: Cycle) -> Bool {
            let startsKnown = candidate.start != nil && current.start != nil
            guard let a = startsKnown ? candidate.start : candidate.resetsAt,
                  let b = startsKnown ? current.start : current.resetsAt else { return false }
            return abs(a.timeIntervalSince(b)) < 60
        }

        private func group(_ points: [Reading]) -> [[Reading]] {
            var groups: [[Reading]] = []
            for point in points {
                guard point.isValid, let start = point.start else { continue }
                if let previous = groups.last?.last, let reset = previous.reset,
                   point.at < reset && !(start >= previous.at && previous.used > 0) {
                    groups[groups.count - 1].append(point)
                } else {
                    groups.append([point])
                }
            }
            return groups
        }

        private func confirmedIntervals(_ points: [Reading], _ groups: [[Reading]]) -> ([Interval], Date?) {
            var intervals: [Interval] = []
            var barrier = points.last(where: { !$0.isValid && !$0.isUnusedPrediction })?.at
            func mark(_ date: Date) { if barrier.map({ $0 < date }) ?? true { barrier = date } }
            for (cycle, entries) in groups.enumerated() {
                guard let start = entries.last?.start else { continue }
                var from = start
                var used = 0.0
                var hasBaseline = true
                var includeFrom = true
                for point in entries {
                    if point.at < start {
                        if point.used > 0 {
                            mark(start)
                            hasBaseline = false
                        }
                        continue
                    }
                    if !hasBaseline || point.used < used || point.at < from
                        || (point.at == from && !includeFrom && point.used != used) {
                        mark(point.at)
                        from = point.at
                        used = point.used
                        includeFrom = false
                        hasBaseline = true
                        continue
                    }
                    guard point.used > used else { continue }
                    intervals.append(Interval(from: from, to: point.at, used: point.used - used,
                                              cycle: cycle, includeFrom: includeFrom))
                    from = point.at
                    used = point.used
                    includeFrom = false
                }
            }
            return (intervals, barrier)
        }

        private mutating func confirmedCost(_ interval: Interval, includeTo: Bool, key: AccountWindow)
            -> (totals: Totals, partial: Bool, unattributed: Int) {
            var totals = Totals()
            let unattributed = unattributedCount(for: key.provider, from: interval.from, to: interval.to,
                                                 includeFrom: interval.includeFrom, includeTo: includeTo)
            for (offset, index) in attributedRows(for: key, from: interval.from, to: interval.to,
                                                   includeFrom: interval.includeFrom, includeTo: includeTo).enumerated() {
                if offset.isMultiple(of: 1024), Task.isCancelled { return (Totals(), true, unattributed) }
                totals.add(cost(index), tokens: rows[index].totalTokens)
            }
            let partial = (firstAt.map { $0 > interval.from } ?? true)
                || unattributed > 0 || totals.unpriced > 0 || totals.overflowed || totals.priced == 0
            return (totals, partial, unattributed)
        }

        private mutating func recentUsage(for key: AccountWindow, points: [Reading], groups: [[Reading]]) -> RecentUsage {
            var result = RecentUsage()
            let (intervals, barrier) = confirmedIntervals(points, groups)
            var amount = 0.0
            var priced = 0
            var cycles: Set<Int> = []
            var newer: Interval?
            for interval in intervals.reversed() {
                if (barrier.map { interval.from < $0 || interval.to < $0 } ?? false)
                    || (newer.map { interval.to > $0.from } ?? false) {
                    result.status = .partialHistory
                    break
                }
                let includeTo = newer.map { !$0.includeFrom || interval.to != $0.from } ?? true
                let (totals, partialCost, unattributed) = confirmedCost(interval, includeTo: includeTo, key: key)
                result.coverageIncomplete = result.coverageIncomplete || partialCost
                result.unattributedRequests += unattributed
                let remaining = 100 - result.usedPercent
                let consumed = min(remaining, interval.used)
                let fraction = consumed / interval.used
                if !totals.overflowed {
                    amount += Double(totals.nanos) / 1e9 * fraction
                    priced += totals.priced
                }
                result.requests += totals.requests
                result.unpricedRequests += totals.unpriced
                result.excludedRequests += totals.excluded
                cycles.insert(interval.cycle)
                result.usedPercent += consumed
                if consumed < interval.used {
                    result.boundaryProrated = true
                    result.from = interval.to.addingTimeInterval(-interval.to.timeIntervalSince(interval.from) * fraction)
                } else {
                    result.from = interval.from
                }
                if result.to == nil { result.to = interval.to }
                newer = interval
                if consumed == remaining {
                    result.usedPercent = 100
                    if priced > 0 {
                        result.status = .ready
                        result.costUSD = amount
                    } else {
                        result.status = .unpriced
                    }
                    break
                }
            }
            if result.status == .insufficientHistory && barrier != nil { result.status = .partialHistory }
            result.cycleCount = cycles.count
            if priced > 0 {
                result.observedCostUSD = amount
            }
            return result
        }
    }
}
