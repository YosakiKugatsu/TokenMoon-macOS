// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Summarizes the same filtered requests and prices shown in a session's request table.
public struct SessionDetailInsights: Equatable, Sendable {
    public struct Model: Identifiable, Equatable, Sendable {
        public let id: String
        public let tokens: Int64
        public let costUSD: Double?
        public let requests: Int
        public let unpricedRequests: Int

        fileprivate init(id: String, metrics: UsageMetrics) {
            self.id = id
            tokens = metrics.tokens
            costUSD = metrics.cost
            requests = metrics.requests
            unpricedRequests = metrics.unpricedRequests
        }
    }

    public struct Day: Identifiable, Equatable, Sendable {
        /// Start of the day in the display calendar.
        public let id: Date
        /// Request counts at local hours 0–23. Repeated clock hours share a cell.
        public let hours: [Int]
        public var requests: Int { hours.reduce(0, +) }
    }

    public let models: [Model]
    /// Includes zero-activity days for spans of up to 31 days. Longer spans include only active days.
    public let activityDays: [Day]
    public let activityPeak: Int

    public init(requests: [UsageRequest], costs: [UsageKey: RequestCost], calendar: Calendar) {
        var byModel: [String: UsageMetrics] = [:]
        var binsByDay: [Date: [Int]] = [:]
        var peak = 0
        for request in requests {
            let modelID = request.modelFacetIdentity ?? "unknown"
            byModel[modelID, default: .init()].add(request, cost: costs[request.key] ?? .unknown)

            let day = calendar.startOfDay(for: request.timestamp)
            let hour = calendar.component(.hour, from: request.timestamp)
            guard (0..<24).contains(hour) else { continue }
            binsByDay[day, default: Self.emptyHours][hour] += 1
            peak = max(peak, binsByDay[day]?[hour] ?? 0)
        }
        models = byModel.map { Model(id: $0.key, metrics: $0.value) }.sorted {
            $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens
        }
        activityPeak = peak

        let activeDates = binsByDay.keys.sorted()
        let dates = Self.shortSpan(activeDates, calendar: calendar) ?? activeDates
        activityDays = dates.map { Day(id: $0, hours: binsByDay[$0] ?? Self.emptyHours) }
    }

    private static let emptyHours = Array(repeating: 0, count: 24)

    private static func shortSpan(_ activeDates: [Date], calendar: Calendar) -> [Date]? {
        guard var day = activeDates.first, let last = activeDates.last else { return [] }
        var dates: [Date] = []
        for _ in 0..<31 {
            dates.append(day)
            if day == last { return dates }
            guard let next = calendar.dateInterval(of: .day, for: day)?.end,
                  next > day, next <= last else { break }
            day = next
        }
        return nil
    }
}
