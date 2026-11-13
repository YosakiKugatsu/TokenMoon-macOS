// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import Foundation

public enum PriceSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case omc, publicCatalog
    public var id: String { rawValue }
    public var label: String { self == .omc ? "OMC" : "公开价目 · models.dev" }
}

public enum RequestCost: Equatable, Sendable {
    case priced(Int64)
    /// Includes reported one-hour writes priced using the generic write rate.
    case pricedWithCacheWriteFallback(Int64)
    case unknown
    case excluded

    public var usd: Double? {
        switch self {
        case let .priced(nanos), let .pricedWithCacheWriteFallback(nanos): Double(nanos) / 1_000_000_000
        case .unknown, .excluded: nil
        }
    }

    public var usesCacheWriteFallback: Bool {
        if case .pricedWithCacheWriteFallback = self { return true }
        return false
    }
}

public enum ServiceTier: String, CaseIterable, Sendable {
    case fast, ultraFast, standard, flex, scale, unknown
    public var label: String {
        switch self {
        case .fast: "Fast"
        case .ultraFast: "UltraFast"
        case .standard: "Standard"
        case .flex: "Flex"
        case .scale: "Scale"
        case .unknown: "未知"
        }
    }
    public init(_ raw: String?) {
        switch raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-") {
        case "priority", "fast": self = .fast
        case "ultrafast", "ultra-fast": self = .ultraFast
        case "default", "standard", "normal": self = .standard
        case "flex": self = .flex
        case "scale": self = .scale
        default: self = .unknown
        }
    }
}

public struct PricingEngine: Sendable {
    public let book: PriceBook
    public let fastMultiplier: Decimal
    public let ultraFastMultiplier: Decimal
    public let fastMultipliersByChannel: [String: Decimal]

    public init(book: PriceBook, fastMultiplier: Double = 2.5, ultraFastMultiplier: Double = 1,
                fastMultipliersByChannel: [String: Double] = [:]) {
        self.book = book
        self.fastMultiplier = Self.factor(fastMultiplier) ?? 2.5
        self.ultraFastMultiplier = Self.factor(ultraFastMultiplier) ?? 1
        self.fastMultipliersByChannel = fastMultipliersByChannel.compactMapValues(Self.factor)
    }

    private static func factor(_ value: Double) -> Decimal? {
        guard value.isFinite, value > 0, value <= 100 else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }

    public func cost(_ request: UsageRequest) -> RequestCost {
        if request.modelIdentity == "codex-auto-review" || (request.isFailure && request.totalTokens == 0) { return .excluded }
        guard let price = book.rows[request.requestedModel] ?? book.rows[request.modelIdentity] else { return .unknown }
        if request.totalTokens == 0 { return .priced(0) }
        let tier = price.tier(for: request)
        var amount = Decimal(0)
        for (index, tokens) in [request.inputTokens, request.outputTokens, request.cacheReadTokens].enumerated() where tokens > 0 {
            guard let rate = tier?.rates[index] ?? price.rates[index] else { return .unknown }
            amount += rate * Decimal(tokens)
        }
        var cacheWriteFallback = false
        if request.cacheWriteTokens > 0 {
            let oneHour = request.cacheWrite1hTokens ?? 0
            let validSplit = oneHour > 0 && oneHour <= request.cacheWriteTokens
                && (request.cacheWrite5mTokens ?? 0) <= request.cacheWriteTokens - oneHour
            let genericRate = tier?.rates[3] ?? price.rates[3]
            // A context/time tier with its own generic cache-write rate may
            // use different TTL prices. Do not borrow a base 1h rate in that case.
            let oneHourRate = tier?.rates[4] ?? (tier?.rates[3] == nil ? price.rates[4] : nil)
            if validSplit, let oneHourRate {
                amount += oneHourRate * Decimal(oneHour)
                let remainder = request.cacheWriteTokens - oneHour
                if remainder > 0 {
                    guard let genericRate else { return .unknown }
                    amount += genericRate * Decimal(remainder)
                }
            } else {
                guard let genericRate else { return .unknown }
                amount += genericRate * Decimal(request.cacheWriteTokens)
                cacheWriteFallback = oneHour > 0
            }
        }
        guard let base = Self.roundNanos(amount * price.multiplier * 1000) else { return .unknown }
        let actual = ServiceTier(request.serviceTier)
        let estimate = actual == .unknown ? ServiceTier(request.requestedServiceTier) : actual
        let factor = estimate == .fast ? (fastMultipliersByChannel[request.channelIdentity] ?? fastMultiplier)
            : estimate == .ultraFast ? ultraFastMultiplier : 1
        guard let nanos = Self.roundNanos(Decimal(base) * factor) else { return .unknown }
        return cacheWriteFallback ? .pricedWithCacheWriteFallback(nanos) : .priced(nanos)
    }

    private static func roundNanos(_ amount: Decimal) -> Int64? {
        var original = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 0, .plain)
        guard !rounded.isNaN, rounded >= 0, rounded <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

public struct PriceBook: Sendable {
    fileprivate let rows: [String: PriceRow]
    public let count: Int
    public static let empty = PriceBook(rows: [:])

    private init(rows: [String: PriceRow]) {
        self.rows = rows
        count = rows.count
    }

    public static func bundledPublic() throws -> PriceBook {
        guard let url = Bundle.main.url(forResource: "public-prices", withExtension: "json")
            ?? Bundle.module.url(forResource: "public-prices", withExtension: "json") else {
            throw PriceBookError.invalid
        }
        return try decode(Data(contentsOf: url), as: .publicCatalog)
    }

    public static func decode(_ data: Data, as source: PriceSource) throws -> PriceBook {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PriceBookError.invalid }
        var rows: [String: PriceRow] = [:]
        func add(_ model: String, _ row: PriceRow) throws {
            guard !model.isEmpty, model.count <= 512, rows[model] == nil, rows.count < 10_000 else { throw PriceBookError.invalid }
            rows[model] = row
        }
        if source == .omc {
            guard let entries = doc["model_prices"] as? [[String: Any]] else { throw PriceBookError.invalid }
            for entry in entries {
                guard let model = entry["model"] as? String,
                      let multiplier = try decimal(entry["price_multiplier"]), multiplier > 0 else { throw PriceBookError.invalid }
                let rawTiers: [[String: Any]]
                if let tiers = entry["tiers"] as? [[String: Any]] {
                    rawTiers = tiers
                } else if let string = entry["tiers_json"] as? String,
                          let tiers = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [[String: Any]] {
                    rawTiers = tiers
                } else {
                    rawTiers = []
                }
                let tiers = try rawTiers.map {
                    PriceTier(threshold: integer($0["min_prompt_tokens"]) ?? 0,
                              start: integer($0["utc_start"]), end: integer($0["utc_end"]),
                              zone: $0["time_zone"] as? String, rates: try rates($0, keys: omcKeys))
                }
                try add(model, .init(rates: try rates(entry, keys: omcKeys), multiplier: multiplier, tiers: tiers))
            }
        } else if let entries = doc["prices"] as? [[String: Any]] {
            // Accept the normalized public pricebook format as well.
            for entry in entries {
                guard let model = entry["model"] as? String else { throw PriceBookError.invalid }
                let values = try rates(entry, keys: publicKeys)
                guard values[0] != nil, values[1] != nil else { continue }
                let tiers = try (entry["tiers"] as? [[String: Any]] ?? []).map { row -> PriceTier in
                    guard let boundary = integer(row["min_prompt_tokens"]), boundary > 0 else { throw PriceBookError.invalid }
                    return .init(threshold: boundary, rates: try rates(row, keys: publicKeys))
                }
                guard Set(tiers.map(\.threshold)).count == tiers.count else { throw PriceBookError.invalid }
                try add(model, .init(rates: values, multiplier: 1, tiers: tiers))
            }
        } else {
            for provider in ["openai", "anthropic", "google"] {
                let models = (doc[provider] as? [String: Any])?["models"] as? [String: [String: Any]] ?? [:]
                for (model, row) in models {
                    guard let cost = row["cost"] as? [String: Any] else { continue }
                    let values = try rates(cost, keys: publicKeys)
                    guard values[0] != nil, values[1] != nil else { continue }
                    var tiers: [PriceTier] = []
                    if let entries = cost["tiers"] as? [[String: Any]] {
                        for entry in entries {
                            guard let boundary = entry["tier"] as? [String: Any],
                                  boundary["type"] as? String == "context",
                                  let threshold = integer(boundary["size"]), threshold > 0 else { throw PriceBookError.invalid }
                            tiers.append(.init(threshold: threshold, rates: try rates(entry, keys: publicKeys)))
                        }
                    } else if let legacy = cost["context_over_200k"] as? [String: Any], !legacy.isEmpty {
                        tiers = [try .init(threshold: 200_001, rates: rates(legacy, keys: publicKeys))]
                    }
                    guard Set(tiers.map(\.threshold)).count == tiers.count else { throw PriceBookError.invalid }
                    try add(model, .init(rates: values, multiplier: 1, tiers: tiers))
                }
            }
        }
        guard !rows.isEmpty else { throw PriceBookError.invalid }
        return .init(rows: rows)
    }

    private static let omcKeys = ["prompt_price_per_1m", "completion_price_per_1m", "cache_read_price_per_1m",
                                  "cache_write_price_per_1m", "cache_write_1h_price_per_1m"]
    private static let publicKeys = ["input", "output", "cache_read", "cache_write", "cache_write_1h"]
    private static func rates(_ object: [String: Any], keys: [String]) throws -> [Decimal?] {
        try keys.map { try decimal(object[$0]) }
    }
    private static func decimal(_ value: Any?) throws -> Decimal? {
        if value == nil || value is NSNull { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let result = Decimal(string: n.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              !result.isNaN, result >= 0, result <= 1_000_000 else { throw PriceBookError.invalid }
        return result
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Int(n.stringValue)
    }
}

public enum PriceBookError: LocalizedError {
    case invalid
    public var errorDescription: String? { "价目表格式无效、为空，或存在冲突的模型或价格。" }
}

private struct PriceRow: Sendable {
    let rates: [Decimal?]
    let multiplier: Decimal
    let tiers: [PriceTier]

    func tier(for request: UsageRequest) -> PriceTier? {
        var selected: PriceTier?
        for tier in tiers where tier.matches(request) {
            if let selected {
                if tier.threshold < selected.threshold || (tier.threshold == selected.threshold && (!tier.hasWindow || selected.hasWindow)) {
                    continue
                }
            }
            selected = tier
        }
        return selected
    }
}

private struct PriceTier: Sendable {
    let threshold: Int
    let start: Int?
    let end: Int?
    private let calendar: Calendar?
    let rates: [Decimal?]

    init(threshold: Int, start: Int? = nil, end: Int? = nil, zone: String? = nil, rates: [Decimal?]) {
        self.threshold = threshold
        self.start = start
        self.end = end
        self.rates = rates
        if start != nil && end != nil {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone ?? "UTC") ?? .gmt
            self.calendar = calendar
        } else {
            self.calendar = nil
        }
    }

    var hasWindow: Bool { start != nil && end != nil }
    func matches(_ request: UsageRequest) -> Bool {
        guard (threshold > 0 || hasWindow), request.inputWithCache >= Int64(threshold) else { return false }
        guard let start, let end else { return true }
        guard [start, end].allSatisfy({ (0...2359).contains($0) && $0 % 100 < 60 }), start != end,
              let calendar else { return false }
        let clock = calendar.dateComponents([.hour, .minute], from: request.timestamp)
        let minute = (clock.hour ?? 0) * 100 + (clock.minute ?? 0)
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }
}
