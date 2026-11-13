// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The official observations and the independently priced request ledger for one weekly quota series.
public struct QuotaDepletionChart: Equatable, Sendable {
    public struct Reading: Identifiable, Equatable, Sendable {
        public let at: Date
        public let remainingPercent: Double
        /// Only readings in the same segment may be connected.
        public let segment: Int
        public let resetsAt: Date?
        public var id: Date { at }
    }

    public struct Device: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let costUSD: Double?
        public let requests: Int
        public let pricedRequests: Int
        public let unpricedRequests: Int
        public let excludedRequests: Int
    }

    public struct Bucket: Identifiable, Equatable, Sendable {
        /// Civil-time bucket clipped to the selected half-open range.
        public let bounds: Range<Date>
        /// Nil for empty or wholly unpriced buckets; priced or excluded zero is distinct.
        public let costUSD: Double?
        public let requests: Int
        public let pricedRequests: Int
        public let unpricedRequests: Int
        public let excludedRequests: Int
        public let devices: [Device]
        public var id: Date { bounds.lowerBound }
    }

    public let seriesID: String
    public let bounds: Range<Date>
    public let interval: UsageBucketInterval
    public let readings: [Reading]
    public let buckets: [Bucket]
    public let costUSD: Double?
    public let requests: Int
    public let pricedRequests: Int
    public let unpricedRequests: Int
    public let excludedRequests: Int
    public let devices: [Device]

    /// Pass the merged ledger before applying dashboard facets. The selected price index must
    /// use the same pricing settings as `pricing`; uncached requests use that engine.
    public static func build(
        seriesID: String, observations: [QuotaWireObservation], requests: [UsageRequest], pricing: PricingEngine,
        deviceNames: [String: String] = [:], costs: [UsageKey: RequestCost] = [:], bounds: Range<Date>,
        interval: UsageBucketInterval, calendar: Calendar
    ) -> Self? {
        guard !bounds.isEmpty, bounds.lowerBound.timeIntervalSinceReferenceDate.isFinite,
              bounds.upperBound.timeIntervalSinceReferenceDate.isFinite, !seriesID.isEmpty,
              let series = officialSeries(id: seriesID, observations: observations, bounds: bounds),
              let provider = UsageQuotaInsights.Provider(agent: series.key.agent) else { return nil }

        var bucketInterval = interval
        var grid = bucketInterval.buckets(in: bounds, calendar: calendar)
        // The shared calendar helper caps the number of buckets. Never silently
        // leave the end of a large range out of the spending series.
        if grid.last.map({ $0.end < bounds.upperBound }) == true {
            bucketInterval = .recommended(for: bounds.lowerBound...bounds.upperBound, calendar: calendar)
            grid = bucketInterval.buckets(in: bounds, calendar: calendar)
        }
        guard let last = grid.last, last.end >= bounds.upperBound else { return nil }
        let binBounds = grid.map { max($0.start, bounds.lowerBound)..<min($0.end, bounds.upperBound) }
        var builders = Array(repeating: Accumulator(), count: binBounds.count)
        var total = Accumulator()
        var seen: Set<UsageKey> = []
        for (index, row) in requests.enumerated() {
            if index.isMultiple(of: 1024), Task.isCancelled { return nil }
            guard bounds.contains(row.timestamp),
                  row.account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == series.email,
                  row.loginMethodEvidence != .conflicting,
                  !isExcludedLogin(row.loginMethod),
                  requestProvider(row) == provider,
                  seen.insert(row.key).inserted else { continue }
            let position = binIndex(containing: row.timestamp, in: binBounds)
            guard position < binBounds.count, binBounds[position].contains(row.timestamp) else { continue }
            let cost = costs[row.key] ?? pricing.cost(row)
            let device = row.key.deviceID
            builders[position].add(cost, device: device)
            total.add(cost, device: device)
        }
        return Self(
            seriesID: seriesID, bounds: bounds, interval: bucketInterval, readings: series.readings,
            buckets: zip(binBounds, builders).map { bin, builder in
                Bucket(bounds: bin, costUSD: builder.totals.costUSD, requests: builder.totals.requests,
                       pricedRequests: builder.totals.priced, unpricedRequests: builder.totals.unpriced,
                       excludedRequests: builder.totals.excluded, devices: builder.devices(named: deviceNames))
            },
            costUSD: total.totals.costUSD, requests: total.totals.requests, pricedRequests: total.totals.priced,
            unpricedRequests: total.totals.unpriced, excludedRequests: total.totals.excluded,
            devices: total.devices(named: deviceNames)
        )
    }
}

private extension QuotaDepletionChart {
    static let unmaskedAddress = try! NSRegularExpression(
        pattern: #"[a-z0-9.!#$%&'+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+"#
    )

    static func officialEmail(_ raw: String) -> String? {
        guard let email = creatorAccountEmail(raw)?.lowercased() else { return nil }
        let whole = NSRange(email.startIndex..., in: email)
        return unmaskedAddress.firstMatch(in: email, range: whole)?.range == whole ? email : nil
    }

    static func isExcludedLogin(_ raw: String?) -> Bool {
        let method = raw?.lowercased().filter(\.isLetter) ?? ""
        return method.hasPrefix("apikey") || method.hasPrefix("upstreamapikey")
            || ["api", "key", "bearerkey", "unknown", "unverified", "unconfirmed", "ambiguous", "conflicting"].contains(method)
    }

    static func requestProvider(_ row: UsageRequest) -> UsageQuotaInsights.Provider? {
        func known(_ value: String?) -> UsageQuotaInsights.Provider? {
            switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "openai", "codex", "chatgpt", "gpt / codex": .codex
            case "anthropic", "claude", "claude.ai": .claude
            case "google", "gemini", "vertex", "vertex-ai", "antigravity": .gemini
            default: nil
            }
        }
        if let upstream = known(row.providerID) ?? known(row.provider) { return upstream }
        switch row.agentGroup {
        case .codex: return .codex
        case .claude: return .claude
        case .gemini, .antigravity: return .gemini
        case .other: return known(row.channelIdentity)
        }
    }

    struct Series {
        let key: QuotaSeriesKey
        let email: String
        let readings: [Reading]
    }

    static func officialSeries(id: String, observations: [QuotaWireObservation], bounds: Range<Date>) -> Series? {
        var selected: QuotaSeriesKey?
        var unrelated: Set<QuotaSeriesKey> = []
        var weekly = false
        var unique: [QuotaSampleKey: QuotaWireObservation] = [:]
        var conflicts: Set<QuotaSampleKey> = []
        for (index, sample) in observations.enumerated() {
            if index.isMultiple(of: 1024), Task.isCancelled { return nil }
            guard sample.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  sample.observedAt <= bounds.upperBound, !sample.windowID.isEmpty else { continue }
            let key = sample.seriesKey
            if let selected {
                guard selected == key else { continue }
            } else {
                guard !unrelated.contains(key) else { continue }
                guard key.id == id else {
                    unrelated.insert(key)
                    continue
                }
                selected = key
            }
            weekly = weekly || sample.durationSeconds == QuotaDepletion.weeklySeconds
            let identity = sample.sampleKey
            guard !conflicts.contains(identity) else { continue }
            if let prior = unique[identity] {
                // Match the option's measurement identity; display labels and plans do not
                // make an otherwise identical measurement disagree.
                if prior.usedPercent != sample.usedPercent || prior.resetsAt != sample.resetsAt
                    || prior.durationSeconds != sample.durationSeconds {
                    unique.removeValue(forKey: identity)
                    conflicts.insert(identity)
                    continue
                }
                if prior.observedAt <= sample.observedAt { continue }
            }
            unique[identity] = sample
        }
        guard weekly, let selected, let email = officialEmail(selected.account) else { return nil }

        var points: [(at: Date, sample: QuotaWireObservation?)] = unique.values
            .filter { bounds.contains($0.observedAt) }
            .map { ($0.observedAt, $0) }
        points += conflicts.map { Date(timeIntervalSince1970: $0.milliseconds / 1_000) }
            .filter { bounds.contains($0) }.map { ($0, nil) }
        points.sort { $0.at < $1.at }

        var result: [Reading] = []
        var previous: (at: Date, used: Double, reset: Date)?
        var segment = -1
        for point in points {
            guard let sample = point.sample, (0...100).contains(sample.usedPercent) else {
                previous = nil
                continue
            }
            let reset = sample.resetsAt.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
            if let reset, let duration = sample.durationSeconds,
               duration > 0, duration <= 366 * 86_400 {
                let start = reset.addingTimeInterval(-duration)
                if sample.usedPercent == 0, point.at < start { continue } // Unused future prediction.
                guard start <= point.at, point.at < reset else {
                    previous = nil
                    continue
                }
                if let prior = previous {
                    let newCycle = point.at >= prior.reset || (start >= prior.at && prior.used > 0)
                    if newCycle || sample.usedPercent < prior.used { segment += 1 }
                } else {
                    segment += 1
                }
                previous = (point.at, sample.usedPercent, reset)
            } else {
                // A real reading can be shown, but without its reset evidence it
                // cannot be connected to a preceding or following cycle.
                segment += 1
                previous = nil
            }
            result.append(.init(at: point.at, remainingPercent: 100 - sample.usedPercent, segment: segment, resetsAt: reset))
        }
        return Series(key: selected, email: email, readings: result)
    }

    static func binIndex(containing at: Date, in bins: [Range<Date>]) -> Int {
        var low = 0, high = bins.count
        while low < high {
            let mid = (low + high) / 2
            if bins[mid].upperBound <= at { low = mid + 1 } else { high = mid }
        }
        return low
    }

    struct Totals {
        var priced = 0
        var unpriced = 0
        var excluded = 0
        var nanos: Decimal = 0

        var requests: Int { priced + unpriced + excluded }
        var costUSD: Double? {
            guard priced > 0 || (excluded > 0 && unpriced == 0) else { return nil }
            return NSDecimalNumber(decimal: nanos / 1_000_000_000).doubleValue
        }

        mutating func add(_ cost: RequestCost) {
            switch cost {
            case let .priced(value), let .pricedWithCacheWriteFallback(value):
                priced += 1
                nanos += Decimal(value)
            case .unknown: unpriced += 1
            case .excluded: excluded += 1
            }
        }
    }

    struct Accumulator {
        var totals = Totals()
        var byDevice: [String: Totals] = [:]

        mutating func add(_ cost: RequestCost, device: String) {
            totals.add(cost)
            byDevice[device, default: Totals()].add(cost)
        }

        func devices(named names: [String: String]) -> [Device] {
            byDevice.map { id, counts in
                Device(id: id, name: names[id] ?? id, costUSD: counts.costUSD, requests: counts.requests,
                       pricedRequests: counts.priced, unpricedRequests: counts.unpriced, excludedRequests: counts.excluded)
            }.sorted {
                let left = $0.costUSD ?? -1, right = $1.costUSD ?? -1
                if left != right { return left > right }
                if $0.requests != $1.requests { return $0.requests > $1.requests }
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
            }
        }
    }
}
