// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct QuotaDepletionChartTests {
    @Test func plotsOnlyOfficialReadingsAndPricesOnlyTheSameAccountAcrossDevices() throws {
        let midnight = Date(timeIntervalSince1970: 1_764_547_200)
        let email = "main@example.test"
        func hour(_ h: Double) -> Date { midnight.addingTimeInterval(h * 3600) }
        func sample(_ at: Double, _ used: Double, reset: Double = 2, label: String = "7 days") -> QuotaWireObservation {
            .init(agent: .codex, account: email, windowID: "weekly", windowLabel: label,
                  observedAt: hour(at), usedPercent: used, resetsAt: hour(reset),
                  durationSeconds: QuotaDepletion.weeklySeconds)
        }
        let bounds = hour(0.5)..<hour(4.5)
        let readings = [
            sample(0.25, 10), sample(0.5, 20), sample(0.75, 25), sample(0.75, 25, label: "7 天"),
            sample(1, 30), sample(1, 31), // Conflict is a gap, not an arbitrary choice.
            sample(1.25, 50), sample(1.5, 0, reset: 170), // Future unused prediction is ignored.
            sample(1.625, 60), sample(1.75, 55), // Downward correction starts a separate segment.
            sample(2.25, 5, reset: 170), sample(2.5, 10, reset: 170), sample(4.5, 20, reset: 170),
        ]
        let option = try #require(QuotaDepletion.options(observations: readings, bounds: bounds).first)
        func row(_ id: String, at: Double = 0.75, account: String? = "main@example.test",
                 method: String? = "oauth", agent: Agent = .codex, upstream: String? = nil,
                 model: String = "gpt-fixture", tokens: Int64 = 1_000_000,
                 device: String = "Mini", tier: String? = nil, creator: String? = nil,
                 loginEvidence: LoginMethodEvidence? = nil) -> UsageRequest {
            .init(id: id, sessionID: id, deviceID: device, agent: agent, timestamp: hour(at),
                  requestedModel: model, providerID: upstream, account: account, loginMethod: method,
                  requestedServiceTier: tier, status: "success", outputTokens: tokens, channel: "GPT / Codex",
                  loginMethodEvidence: loginEvidence, sessionCreatorAccountEmail: creator)
        }
        let native = row("native", at: 0.5)
        let gateway = row("gateway", account: "MAIN@example.test", method: "manual-confirmed",
                          agent: .cpa, upstream: "openai", device: "Gateway", tier: "fast")
        let requests = [
            native, native, gateway,
            row("unknown", at: 1, model: "unpriced-fixture"),
            row("known-zero", at: 2, tokens: 0),
            row("excluded", at: 3, model: "codex-auto-review"),
            row("key", method: "API_Key"),
            row("masked", account: "m***n@example.test"),
            row("wrong-account", account: "different@example.test"),
            row("creator", account: nil, creator: email),
            row("conflict", method: nil, loginEvidence: .conflicting),
            row("other-provider", agent: .cpa, upstream: "anthropic"),
            row("before", at: 0.25), row("after", at: 4.5),
        ]
        let json = #"{ "model_prices": [{"model":"gpt-fixture","completion_price_per_1m":2,"price_multiplier":1}] }"#
        let book = try PriceBook.decode(Data(json.utf8), as: .omc)
        let pricing = PricingEngine(book: book, fastMultiplier: 2, fastMultipliersByChannel: ["GPT / Codex": 3])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let chart = try #require(QuotaDepletionChart.build(
            seriesID: option.id, observations: readings.reversed(), requests: requests, pricing: pricing,
            deviceNames: ["mini": "Example Mac", "gateway": "CPA"], costs: [native.key: .priced(1_000_000_000)],
            bounds: bounds, interval: .hour, calendar: calendar
        ))

        #expect(chart.readings.map(\.at) == [0.5, 0.75, 1.25, 1.625, 1.75, 2.25, 2.5].map(hour))
        #expect(chart.readings.map(\.remainingPercent) == [80, 75, 50, 40, 45, 95, 90])
        #expect(chart.readings.map(\.segment) == [0, 0, 1, 1, 2, 3, 3])
        #expect(chart.buckets.map(\.bounds) == [hour(0.5)..<hour(1), hour(1)..<hour(2), hour(2)..<hour(3),
                                                 hour(3)..<hour(4), hour(4)..<hour(4.5)])
        // Cache takes precedence for the native row; the uncached CPA row uses the channel's Fast price.
        #expect(chart.buckets.map(\.costUSD) == [7, nil, 0, 0, nil])
        #expect(chart.buckets.map(\.requests) == [2, 1, 1, 1, 0])
        #expect(chart.buckets[0].devices.map(\.name) == ["CPA", "Example Mac"])
        #expect(chart.buckets[0].devices.map(\.costUSD) == [6, 1])
        #expect(chart.costUSD == 7 && chart.requests == 5 && chart.pricedRequests == 3
                && chart.unpricedRequests == 1 && chart.excludedRequests == 1)
    }
}
