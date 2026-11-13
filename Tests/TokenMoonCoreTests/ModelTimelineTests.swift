// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import TokenMoonCore

private func instant(_ value: String) throws -> Date {
    try Date.ISO8601FormatStyle().parse(value)
}

private func request(_ id: String, at date: Date, requested: String, sent: String? = nil,
                     input: Int64 = 0, output: Int64 = 0, read: Int64 = 0, write: Int64 = 0) -> UsageRequest {
    UsageRequest(id: id, sessionID: "fixture", deviceID: "test-mac", agent: .codex, timestamp: date,
                 requestedModel: requested, sentModel: sent, inputTokens: input, outputTokens: output,
                 cacheReadTokens: read, cacheWriteTokens: write)
}

@Test func modelTimelinePreservesMetricsAndLeavesEmptyCellsSparse() throws {
    let start = try instant("2026-11-10T00:00:00Z")
    let thirdHour = start.addingTimeInterval(7_200)
    let end = start.addingTimeInterval(10_800)
    let calendar = UsageDisplayTime.calendar(in: TimeZone(secondsFromGMT: 0)!)
    let priced = request("one", at: start, requested: "route-alias", sent: "model-a", input: 200, output: 1_500, read: 800)
    let fallback = request("two", at: start.addingTimeInterval(12), requested: "model-a", input: 100, output: 2_000)
    let unpriced = request("three", at: start.addingTimeInterval(72), requested: "model-b", input: 50, output: 30, read: 150, write: 50)
    let excluded = request("four", at: thirdHour, requested: "model-c", output: 7)
    let outside = request("outside", at: end, requested: "model-outside", input: 99)

    let snapshot = UsageSnapshot(requests: [excluded, unpriced, outside, fallback, priced], range: .custom,
                                 bounds: start..<end, calendar: calendar, prices: .init(book: .empty),
                                 precomputedCosts: [priced.key: .priced(250_000_000),
                                                    fallback.key: .pricedWithCacheWriteFallback(750_000_000),
                                                    excluded.key: .excluded])
    let first = try #require(snapshot.timeline.first)
    #expect(snapshot.timeline.map(\.metrics.requests) == [3, 0, 1])
    #expect(snapshot.modelTimeline.map(\.modelIdentity) == ["model-a", "model-b", "model-c"])
    #expect(snapshot.modelTimeline.map(\.date) == [start, start, thirdHour])
    #expect(snapshot.modelTimeline.map(\.endDate) == [first.endDate, first.endDate, end])
    let a = snapshot.modelTimeline[0].metrics
    let b = snapshot.modelTimeline[1].metrics
    let c = snapshot.modelTimeline[2].metrics
    #expect(a.requests + b.requests == first.metrics.requests)
    #expect(a.tokens + b.tokens == first.metrics.tokens)
    #expect(a.cost == first.metrics.cost && a.cost == 1)
    #expect(a.cacheWriteFallbackRequests == 1)
    #expect(b.cost == nil && b.unpricedRequests == 1)
    #expect(c.cost == 0 && c.excludedRequests == 1 && c.cacheRate == nil)
    #expect(a.cacheRate == 800.0 / 1_100 && b.cacheRate == 150.0 / 250)
    #expect(first.metrics.cacheRate == 950.0 / 1_350)
}

@Test func modelTimelineKeepsBothRepeatedCivilHoursDistinct() throws {
    let first = try instant("2026-11-01T01:00:00-05:00")
    let second = try instant("2026-11-01T01:00:00-06:00")
    let calendar = UsageDisplayTime.calendar(in: try #require(TimeZone(identifier: "America/Chicago")))
    let bounds = UsageRange.custom.bounds(now: second, customStart: first, customEnd: second, calendar: calendar)
    let snapshot = UsageSnapshot(requests: [
        request("second", at: second, requested: "same-model", input: 20),
        request("first", at: second.addingTimeInterval(-1), requested: "same-model", input: 10),
    ], range: .custom, bounds: bounds, calendar: calendar, prices: .init(book: .empty))

    #expect(snapshot.timeline.map(\.date) == [first, second])
    #expect(snapshot.modelTimeline.map(\.date) == snapshot.timeline.map(\.date))
    #expect(snapshot.modelTimeline.map(\.endDate) == snapshot.timeline.map(\.endDate))
    #expect(snapshot.modelTimeline.map(\.metrics.tokens) == [10, 20])
    #expect(Set(snapshot.modelTimeline.map(\.id)).count == 2)
}

@Test func groupedSeriesUseTheirOwnCacheDenominatorsAndTimingSamples() throws {
    let start = try instant("2026-11-10T00:00:00Z")
    let end = start.addingTimeInterval(3_600)
    let calendar = UsageDisplayTime.calendar(in: TimeZone(secondsFromGMT: 0)!)
    let a = UsageRequest(id: "a", sessionID: "fixture", deviceID: "device-a", agent: .claudeDesktop,
                         timestamp: start, requestedModel: "same-model", requestedServiceTier: "fast",
                         estimatedDurationMS: 2_000, estimatedTimingSource: "claude-session-log",
                         inputTokens: 200, outputTokens: 1_600, cacheReadTokens: 800)
    let b = UsageRequest(id: "b", sessionID: "fixture", deviceID: "device-b", agent: .claudeCode,
                         timestamp: start.addingTimeInterval(1), requestedModel: "same-model", requestedServiceTier: "standard",
                         estimatedDurationMS: 6_000, estimatedTimingSource: "claude-session-log",
                         inputTokens: 100, outputTokens: 1_800)
    let rows = [a, b]
    func snapshot(_ dimension: UsageChartDimension) -> UsageSnapshot {
        UsageSnapshot(requests: rows, range: .custom, bounds: start..<end, calendar: calendar,
                      prices: .init(book: .empty), precomputedCosts: [a.key: .priced(1), b.key: .priced(2)],
                      chartGrouping: dimension)
    }
    let devices = snapshot(.device)
    let byDevice = Dictionary(uniqueKeysWithValues: devices.seriesTimeline.map { ($0.seriesIdentity, $0.metrics) })
    let deviceA = try #require(byDevice["device-a"])
    let deviceB = try #require(byDevice["device-b"])
    #expect(deviceA.cacheRate == 0.8)
    #expect(deviceB.cacheRate == 0)
    #expect(deviceA.estimatedTPS == 800)
    #expect(deviceB.estimatedTPS == 300)
    #expect(devices.metrics.estimatedTPS == 425)
    #expect(deviceA.tokens + deviceB.tokens == devices.metrics.tokens)
    #expect(deviceA.requests + deviceB.requests == devices.metrics.requests)
    #expect(devices.seriesTimeline.allSatisfy { $0.endDate == devices.timeline.first?.endDate })
    #expect(snapshot(.model).seriesTimeline.map(\.seriesIdentity) == ["same-model"])
    #expect(snapshot(.agent).seriesTimeline.map(\.seriesIdentity) == [UsageAgentGroup.claude.rawValue])
    #expect(snapshot(.requestedTier).seriesTimeline.map(\.seriesIdentity) == ["fast", "standard"])
}

@Test func automaticChartGroupingUsesLatestMultiSelectionWithVisibleGroups() throws {
    let date = try instant("2026-11-10T00:00:00Z")
    let a = UsageRequest(id: "a", sessionID: "fixture", deviceID: "device-a", agent: .claudeDesktop,
                         timestamp: date, requestedModel: "same-model", requestedServiceTier: "fast")
    let b = UsageRequest(id: "b", sessionID: "fixture", deviceID: "device-b", agent: .claudeCode,
                         timestamp: date, requestedModel: "same-model", requestedServiceTier: "standard")
    let selected: Set<UsageChartDimension> = [.device, .agent, .requestedTier]
    #expect(UsageChartDimension.automatic(recentDimensions: [.requestedTier, .device, .agent],
                                         multiSelected: selected, visibleRows: [a, b]) == .device)
    #expect(UsageChartDimension.automatic(recentDimensions: [.device, .requestedTier],
                                         multiSelected: selected, visibleRows: [a, b]) == .requestedTier)
    #expect(UsageChartDimension.automatic(recentDimensions: [.device, .requestedTier],
                                         multiSelected: selected, visibleRows: [a]) == .model)
}

@Test func accountFilterRejectsVerifiedAPIKeysAcrossSourcesAndKeepsUnknowns() throws {
    let start = try instant("2026-11-10T00:00:00Z")
    let bounds = start..<start.addingTimeInterval(3_600)
    let email = "native-person@example.com"
    let official: UsageAccountFacet = .email(email)
    let masked: UsageAccountFacet = .apiKey("sk-proj-ab***yz")
    func row(_ id: String, _ agent: Agent, account: String? = nil, login: String? = nil,
             creator: String? = nil, evidence: RequestAccountEvidence? = nil,
             loginEvidence: LoginMethodEvidence? = nil) -> UsageRequest {
        .init(id: id, sessionID: "fixture", deviceID: agent.rawValue, agent: agent, timestamp: start,
              requestedModel: "gpt-5", account: account, loginMethod: login, inputTokens: 10,
              loginMethodEvidence: loginEvidence, sessionCreatorAccountEmail: creator, accountEvidence: evidence)
    }
    let rows = [
        row("mac", .codex, account: email, evidence: .userConfirmed),
        row("cpa-oauth", .cpa, account: email.uppercased(), login: "oauth"),
        row("cpa-key", .cpa, account: "sk-proj-ab***yz"),
        row("cpa-explicit-key", .cpa, account: email, login: "API_Key"),
        row("codex-key", .codex, login: "api-key", loginEvidence: .turnTrace),
        row("claude-code-key", .claudeCode, login: "api_key"),
        row("creator-only", .codex, creator: email),
        row("ambiguous-codex", .codex, loginEvidence: .conflicting),
        row("unattributed-claude-code", .claudeCode),
        row("unattributed-cpa", .cpa),
    ]
    let window = UsageWindow(requests: rows, bounds: bounds)
    #expect(window.accounts == [official, masked, .apiKey(nil), .unattributed])

    var resolver = UsageAccountFacet.Resolver()
    let noAPIKeys = window.requests.filter { resolver.includes($0, selected: [], excludesAPIKeys: true) }
    #expect(noAPIKeys.map(\.id) == ["mac", "cpa-oauth", "creator-only", "ambiguous-codex", "unattributed-claude-code", "unattributed-cpa"])
    let apiKeys = window.requests.filter { resolver.includes($0, selected: [.apiKey(nil), masked], excludesAPIKeys: false) }
    #expect(apiKeys.map(\.id) == ["cpa-key", "cpa-explicit-key", "codex-key", "claude-code-key"])
    let justOfficial = window.requests.filter { resolver.includes($0, selected: [official], excludesAPIKeys: false) }
    #expect(justOfficial.map(\.id) == ["mac", "cpa-oauth"])
    let snapshot = UsageSnapshot(requests: noAPIKeys, range: .custom, bounds: bounds, calendar: .current,
                                 prices: .init(book: .empty), chartGrouping: .account)
    let counts = Dictionary(uniqueKeysWithValues: snapshot.seriesTimeline.map { ($0.seriesIdentity, $0.metrics.requests) })
    #expect(counts == [official.id: 2, UsageAccountFacet.unattributed.id: 4])
    #expect(!official.label.contains(email))
    #expect(UsageAccountFacet(id: "key:sk-unmasked-test-value") == nil)
}
