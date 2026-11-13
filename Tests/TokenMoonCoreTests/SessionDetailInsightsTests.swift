// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct SessionDetailInsightsTests {
    @Test func modelBreakdownUsesRequestTableIdentityAndPricing() throws {
        let at = Date(timeIntervalSince1970: 0)
        let cached = request("cached", at: at, model: "routing-alias", sent: "served", input: 30, cacheRead: 20)
        let priced = request("priced", at: at, model: "served", output: 50)
        let unpriced = request("unpriced", at: at, model: "served", output: 20)
        let missingPrice = request("missing-price", at: at, model: "other", output: 10)
        let excluded = request("excluded", at: at, model: "codex-auto-review", output: 10)
        let failedWithoutModel = request("failed", at: at, model: "unknown-model", status: "failed")
        let costs: [UsageKey: RequestCost] = [
            cached.key: .pricedWithCacheWriteFallback(50_000_000),
            priced.key: .priced(150_000_000),
            unpriced.key: .unknown,
            excluded.key: .excluded,
            failedWithoutModel.key: .excluded,
        ]

        let insights = SessionDetailInsights(requests: [
            priced, cached, unpriced, missingPrice, excluded, failedWithoutModel
        ], costs: costs, calendar: utc)

        #expect(insights.models.map(\.id) == ["served", "codex-auto-review", "other", "unknown"])
        let model = try #require(insights.models.first)
        #expect(model.tokens == 120)
        #expect(model.costUSD == 0.2)
        #expect(model.requests == 3)
        #expect(model.unpricedRequests == 1)
        let other = try #require(insights.models.first { $0.id == "other" })
        #expect(other.costUSD == nil)
        #expect(other.unpricedRequests == 1)
        let review = try #require(insights.models.first { $0.id == "codex-auto-review" })
        #expect(review.costUSD == 0)
        #expect(review.unpricedRequests == 0)
        #expect(insights.activityDays.map(\.requests) == [6])
    }

    @Test func activityUsesDisplayMidnightAndMergesRepeatedCivilHour() throws {
        let calendar = UsageDisplayTime.calendar(in: try #require(TimeZone(identifier: "America/New_York")))
        let events = try [
            "2026-11-01T03:59:00Z", // 10/31 23:59 EDT
            "2026-11-01T04:00:00Z", // 11/01 00:00 EDT
            "2026-11-01T05:30:00Z", // 11/01 01:30 EDT
            "2026-11-01T06:30:00Z", // 11/01 01:30 EST
            "2026-11-03T05:00:00Z", // 11/03 00:00 EST
        ].enumerated().map { index, value in request(String(index), at: try date(value)) }
        let insights = SessionDetailInsights(requests: Array(events.reversed()), costs: [:], calendar: calendar)
        let days = insights.activityDays

        #expect(days.map(\.id) == (try [
            date("2026-10-31T04:00:00Z"), date("2026-11-01T04:00:00Z"),
            date("2026-11-02T05:00:00Z"), date("2026-11-03T05:00:00Z"),
        ]))
        #expect(days.allSatisfy { $0.hours.count == 24 })
        #expect(days.map(\.requests) == [1, 3, 0, 1])
        #expect(days[0].hours[23] == 1)
        #expect(days[1].hours[0] == 1)
        #expect(days[1].hours[1] == 2)
        #expect(days[3].hours[0] == 1)
        #expect(insights.activityPeak == 2)
    }

    @Test func longIdleGapsDoNotMaterializeEmptyDays() throws {
        let first = try date("2025-01-01T12:00:00Z")
        let last = try date("2026-01-01T20:00:00Z")
        let insights = SessionDetailInsights(requests: [
            request("last", at: last), request("first", at: first),
        ], costs: [:], calendar: utc)
        #expect(insights.activityDays.map(\.id) == [utc.startOfDay(for: first), utc.startOfDay(for: last)])
        #expect(insights.activityDays.map(\.requests) == [1, 1])
        #expect(insights.activityPeak == 1)
    }

    private var utc: Calendar { UsageDisplayTime.calendar(in: TimeZone(secondsFromGMT: 0)!) }

    private func date(_ value: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(value)
    }

    private func request(_ id: String, at time: Date, model: String = "served", sent: String? = nil,
                         status: String = "success", input: Int64 = 0, output: Int64 = 0,
                         cacheRead: Int64 = 0) -> UsageRequest {
        .init(id: id, sessionID: "session", deviceID: "device", agent: .codex, timestamp: time,
              requestedModel: model, sentModel: sent, status: status, inputTokens: input,
              outputTokens: output, cacheReadTokens: cacheRead)
    }
}
