// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

private func localCalendar(_ zone: String = "America/Chicago") throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
}

private func instant(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
}

private func request(
    _ id: String, _ time: Date, model: String,
    agent: Agent = .codex, device: String = "Mac", tier: String? = nil
) -> UsageRequest {
    .init(id: id, sessionID: id, deviceID: device, agent: agent, timestamp: time,
          requestedModel: model, requestedServiceTier: tier, inputTokens: 1, outputTokens: 1)
}

@Test func customHoursKeepBothEndpointHoursAndOnlyOfferRecordedFilters() throws {
    let calendar = try localCalendar()
    let start = try instant("2026-11-10T09:00:00-06:00")
    let end = try instant("2026-11-10T11:00:00-06:00")
    let stop = try instant("2026-11-10T12:00:00-06:00")
    let bounds = UsageRange.custom.bounds(now: stop, customStart: start, customEnd: end, calendar: calendar)
    let rows = [
        request("before", start.addingTimeInterval(-1), model: "old", agent: .antigravity, device: "Past", tier: "ultrafast"),
        request("first", start, model: "gpt", tier: "fast"),
        request("last", stop.addingTimeInterval(-1), model: "sonnet", agent: .claudeCode, device: "OTHER"),
        request("after", stop, model: "future", agent: .claudeDesktop, tier: "flex")
    ]
    let window = UsageWindow(requests: rows, bounds: bounds)
    #expect(bounds == start..<stop)
    #expect(window.requests.map(\.id) == ["first", "last"])
    #expect(window.models == ["gpt", "sonnet"])
    #expect(window.devices == ["mac", "other"])
    #expect(window.agents == [.codex, .claude])
    #expect(window.tiers == [.fast, .unknown])
    let snapshot = UsageSnapshot(requests: rows, range: .custom, bounds: bounds, calendar: calendar, prices: .init(book: .empty))
    #expect(snapshot.timelineInterval == .hour)
    #expect(snapshot.timeline.map(\.metrics.requests) == [1, 0, 1])
    #expect(snapshot.metrics.requests == 2)
}

@Test func newestFirstWindowRetainsTiedStartsAndOmitsTiedEnds() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let end = start.addingTimeInterval(3600)
    let rows = [
        request("newer", end.addingTimeInterval(1), model: "after"),
        request("end-a", end, model: "after"),
        request("end-b", end, model: "after"),
        request("inside", end.addingTimeInterval(-0.25), model: "inside"),
        request("start-a", start, model: "first"),
        request("start-b", start, model: "second", agent: .claudeCode, device: "OTHER"),
        request("older", start.addingTimeInterval(-0.25), model: "before")
    ]
    let dated = rows[UsageWindow.indices(sortedNewestFirst: rows, bounds: start..<end)]
    #expect(dated.map(\.id) == ["inside", "start-a", "start-b"])
    let facets = UsageWindow.Facets(requests: dated)
    #expect(facets.models == ["inside", "first", "second"])
    #expect(facets.devices == ["mac", "other"])
    #expect(facets.agents == [.codex, .claude])
    #expect(UsageWindow.indices(sortedNewestFirst: rows, bounds: start..<start).isEmpty)
    #expect(UsageWindow.indices(sortedNewestFirst: rows, bounds: .distantPast ..< .distantFuture) == rows.indices)
}

@Test func repeatedAndMissingHoursFollowLocalClock() throws {
    let calendar = try localCalendar()
    let first = try instant("2026-11-01T01:00:00-05:00")
    let second = try instant("2026-11-01T01:00:00-06:00")
    let end = try instant("2026-11-01T02:00:00-06:00")
    let hours = UsageBucketInterval.localHours(on: first, calendar: calendar)
    #expect(hours.count == 25)
    #expect(hours.filter { calendar.component(.hour, from: $0.start) == 1 }.map(\.start) == [first, second])
    let bounds = UsageRange.custom.bounds(now: end, customStart: first, customEnd: second, calendar: calendar)
    #expect(bounds == first..<end)
    let rows = [request("first", second.addingTimeInterval(-1), model: "gpt"),
                request("second", second, model: "gpt")]
    let snapshot = UsageSnapshot(requests: rows, range: .custom, bounds: bounds, calendar: calendar, prices: .init(book: .empty))
    #expect(snapshot.timeline.map(\.date) == [first, second])
    #expect(snapshot.timeline.map(\.metrics.requests) == [1, 1])

    let forward = try instant("2026-03-08T01:00:00-06:00")
    let springHours = UsageBucketInterval.localHours(on: forward, calendar: calendar)
    #expect(springHours.count == 23)
    #expect(!springHours.contains { calendar.component(.hour, from: $0.start) == 2 })
}

@Test func gatewayRequestsShareTheFinalAgentFamilyButKeepTheSourceDevice() throws {
    let now = try instant("2026-11-10T18:00:00Z")
    var codex = request("gateway-codex", now, model: "alias", agent: .cpa, device: "gateway")
    codex.providerID = "codex"
    var claude = request("gateway-claude", now, model: "alias", agent: .cpa, device: "gateway")
    claude.sentModel = "anthropic/claude-sonnet"
    let uncertain = request("gateway-unknown", now, model: "gpt-alias", agent: .cpa, device: "gateway")
    let native = request("desktop-claude", now, model: "claude-sonnet", agent: .claudeDesktop)
    #expect(codex.agentGroup == .codex && codex.agent == .cpa && codex.deviceID == "gateway")
    #expect(claude.agentGroup == native.agentGroup)
    #expect(uncertain.agentGroup == .other)
    let window = UsageWindow(requests: [codex, claude, uncertain, native], bounds: now..<now.addingTimeInterval(1))
    #expect(window.agents == [.codex, .claude, .other])
    #expect(window.devices == ["mac", "gateway"])
}

@Test func partialDstTransitionDoesNotOverlapBuckets() throws {
    let calendar = try localCalendar("Australia/Lord_Howe")
    let after = try instant("2026-10-04T02:30:00+11:00")
    let hours = UsageBucketInterval.localHours(on: after, calendar: calendar)
    let partial = try #require(hours.first { $0.start == after })
    #expect(partial.duration == 1800)
    #expect(zip(hours, hours.dropFirst()).allSatisfy { $0.end == $1.start })
    let bounds = UsageRange.custom.bounds(now: after, customStart: after, customEnd: after, calendar: calendar)
    #expect(bounds == partial.start..<partial.end)
}

@Test func longerSpansUseCalendarBucketsAndAllTimeKeepsItsExtentWhenFiltered() throws {
    let calendar = try localCalendar()
    let now = try instant("2026-11-10T12:00:00-06:00")
    let prices = PricingEngine(book: .empty)
    func snapshot(_ range: UsageRange) -> UsageSnapshot {
        let bounds = range.bounds(now: now, customStart: now, customEnd: now, calendar: calendar)
        return UsageSnapshot(requests: [], range: range, bounds: bounds, calendar: calendar, prices: prices)
    }
    #expect(snapshot(.last24Hours).timelineInterval == .hour)
    #expect(snapshot(.last7Days).timelineInterval == .hours(6))
    #expect(snapshot(.last7Days).timeline.count == 26)
    #expect(snapshot(.last30Days).timelineInterval == .day)
    let quarter = snapshot(.last90Days)
    #expect(quarter.timelineInterval == .days(3))
    #expect((30...31).contains(quarter.timeline.count))
    #expect(quarter.timeline.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
    #expect(quarter.timeline.last?.endDate == now)

    let old = try instant("2025-01-15T12:00:00-06:00")
    let all = UsageRange.all.bounds(now: now, customStart: now, customEnd: now, calendar: calendar)
    let filtered = UsageSnapshot(requests: [request("kept", now, model: "gpt")], range: .all,
                                 bounds: all, calendar: calendar, prices: prices, allTimeSpan: old...now)
    #expect(filtered.timelineInterval == .month)
    #expect(filtered.timeline.count == 23)
    #expect(filtered.timeline.first?.metrics.requests == 0)
    #expect(filtered.timeline.last?.metrics.requests == 1)
}

@Test func rollingDayIsExactly24HoursAndUsesClippedChartBoundsAcrossDaylightSaving() throws {
    let calendar = try localCalendar()
    let now = try instant("2026-11-01T12:17:29-06:00")
    let expectedStart = try instant("2026-10-31T13:17:29-05:00")
    let bounds = UsageRange.last24Hours.bounds(now: now, customStart: now, customEnd: now, calendar: calendar)
    #expect(bounds == expectedStart..<now)
    let rows = [
        request("before", expectedStart.addingTimeInterval(-1), model: "a"),
        request("start", expectedStart, model: "a"),
        request("latest", now.addingTimeInterval(-1), model: "b"),
        request("next", now, model: "b")
    ]
    let snapshot = UsageSnapshot(requests: rows, range: .last24Hours, bounds: bounds, calendar: calendar,
                                 prices: .init(book: .empty))
    #expect(snapshot.timeline.first?.date == expectedStart)
    #expect(snapshot.timeline.last?.endDate == now)
    #expect(snapshot.timeline.first?.metrics.requests == 1)
    #expect(snapshot.timeline.last?.metrics.requests == 1)
    #expect(snapshot.metrics.requests == 2)
    #expect(snapshot.modelTimeline.map(\.date) == [expectedStart, snapshot.timeline.last!.date])
    #expect(zip(snapshot.timeline, snapshot.timeline.dropFirst()).allSatisfy { $0.endDate == $1.date })
}

@Test func adaptiveBucketsUsePlotResolutionAndRespectCivilTimeAtTransitions() throws {
    let calendar = try localCalendar()
    let now = try instant("2026-11-01T20:37:00-06:00")
    let bounds = UsageRange.last7Days.bounds(now: now, customStart: now, customEnd: now, calendar: calendar)
    func snapshot(target: Int) -> UsageSnapshot {
        UsageSnapshot(requests: [], range: .last7Days, bounds: bounds, calendar: calendar,
                      prices: .init(book: .empty), targetBucketCount: target)
    }
    let regular = snapshot(target: 28), compact = snapshot(target: 15), large = snapshot(target: 56)
    #expect(regular.timelineInterval == .hours(6))
    #expect(compact.timelineInterval == .hours(12))
    #expect(large.timelineInterval == .hours(3))
    #expect(regular.timeline.first?.date == bounds.lowerBound)
    #expect(regular.timeline.last?.endDate == now)
    #expect(regular.timeline.allSatisfy { calendar.component(.hour, from: $0.date).isMultiple(of: 6) })
    let fallStart = try instant("2026-11-01T00:00:00-05:00")
    let fallEnd = try instant("2026-11-01T06:00:00-06:00")
    let autumn = try #require(regular.timeline.first { $0.date == fallStart })
    #expect(autumn.endDate == fallEnd && fallEnd.timeIntervalSince(fallStart) == 7 * 3600)
    let spring = try instant("2026-03-08T03:00:00-05:00")
    let springGroup = try #require(UsageBucketInterval.hours(6).interval(containing: spring, calendar: calendar))
    #expect(calendar.component(.hour, from: springGroup.start) == 0)
    #expect(calendar.component(.hour, from: springGroup.end) == 6)
    #expect(springGroup.duration == 5 * 3600)
}
