// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct UsageQuotaInsightsTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_812_800)
    private let email = "one@example.test"
    private let week: Double = 7 * 24

    private func hour(_ value: Double) -> Date { epoch.addingTimeInterval(value * 3600) }

    private func sample(_ at: Double, _ used: Double, start: Double? = 0,
                        account: String = "one@example.test", agent: Agent = .codex) -> QuotaWireObservation {
        .init(agent: agent, account: account, windowID: "weekly", windowLabel: "7 days",
              observedAt: hour(at), usedPercent: used, resetsAt: start.map { hour($0 + week) },
              durationSeconds: start == nil ? nil : week * 3600)
    }

    private func request(_ at: Double, _ amount: Int64, id: String? = nil, device: String = "mini",
                         model: String = "gpt-fixture", account: String? = "one@example.test",
                         login: String? = "oauth", agent: Agent = .codex, channel: String? = "GPT / Codex",
                         status: String = "success", creator: String? = nil, tier: String? = nil) -> UsageRequest {
        .init(id: id ?? String(at), sessionID: "session", deviceID: device, agent: agent, timestamp: hour(at),
              requestedModel: model, account: account, loginMethod: login, requestedServiceTier: tier, status: status,
              outputTokens: amount * 2, channel: channel, sessionCreatorAccountEmail: creator)
    }

    private func engine(_ source: PriceSource = .omc, fast: Double = 2.5) throws -> PricingEngine {
        let json = source == .omc
            ? #"{ "model_prices": [{"model":"gpt-fixture","prompt_price_per_1m":500000,"completion_price_per_1m":500000,"price_multiplier":1}] }"#
            : #"{ "prices": [{"model":"gpt-fixture","input":1000000,"output":1000000}] }"#
        return .init(book: try PriceBook.decode(Data(json.utf8), as: source), fastMultiplier: fast)
    }

    private func evaluate(_ points: [QuotaWireObservation], _ requests: [UsageRequest], at: Double,
                          source: PriceSource = .omc, fast: Double = 2.5,
                          costs: [UsageKey: RequestCost] = [:]) throws -> UsageQuotaInsights.Window {
        let windows = UsageQuotaInsights.evaluate(observations: points, requests: requests, pricing: try engine(source, fast: fast),
                                                   deviceNames: ["mini": "Example Mac", "gateway": "Example Gateway"], costs: costs, at: hour(at))
        return try #require(windows.first)
    }

    @Test func indexedCoverageIsIdenticalForAscendingDescendingAndUnorderedRequests() throws {
        let claude = "claude@example.test"
        let points = [sample(2, 50), sample(2, 25, account: claude, agent: .claudeCode)]
        let rows = [
            request(-1, 1, account: "other@example.test"),
            request(0, 2),
            request(1, 500, model: "claude-fixture", account: nil, agent: .codex, channel: "Claude"),
            request(2, 3, id: "codex-at-observation", device: "gateway", agent: .cpa),
            request(2, 7, id: "claude-at-observation", account: claude, agent: .claudeCode, channel: "Claude"),
            request(2.25, 500)
        ]
        let pricing = try engine()
        func all(_ requests: [UsageRequest]) -> [UsageQuotaInsights.Window] {
            UsageQuotaInsights.evaluate(observations: points, requests: requests, pricing: pricing, at: hour(3))
        }
        let ascending = all(rows)
        #expect(all(Array(rows.reversed())) == ascending)
        #expect(all([rows[3], rows[0], rows[5], rows[2], rows[1], rows[4]]) == ascending)
        let codex = try #require(ascending.first { $0.provider == .codex })
        let anthro = try #require(ascending.first { $0.provider == .claude })
        #expect(codex.requests == 2 && codex.observedCostUSD == 5)
        #expect(codex.unattributedRequests == 1 && codex.recentUsage.unattributedRequests == 1)
        #expect(anthro.requests == 1 && anthro.observedCostUSD == 7)
        #expect(anthro.unattributedRequests == 1 && anthro.recentUsage.unattributedRequests == 1)
    }

    @Test func matchesCPARecentHundredAcrossResetsInBothPriceBooks() throws {
        // Same costs and official percentages as Go TestRecentUsageSelectsLatestConfirmedHundredAcrossResets.
        let points = [sample(1, 30), sample(1.5, 30), sample(2, 40), sample(3, 40),
                      sample(25, 70, start: 24), sample(26, 70, start: 24)]
        let records = [request(0, 0, account: "different@example.test"),
                       request(0.5, 600), request(1.5, 20), request(1.75, 110), request(2.5, 55),
                       request(24.5, 700, device: "gateway", agent: .cpa), request(25.5, 99)]
        for source in PriceSource.allCases {
            let window = try evaluate(points, records, at: 27, source: source)
            let factor = source == .omc ? 1.0 : 2.0
            #expect(window.usedPercent == 70 && window.remainingPercent == 30)
            #expect(window.observedCostUSD == 799 * factor)
            #expect(window.cycles.map(\.usedPercent) == [40, 70])
            #expect(window.cycles.first?.observedCostUSD == 785 * factor)
            #expect(window.cycles.last?.isCurrent == true)
            #expect(window.recentUsage.status == .ready && window.recentUsage.usedPercent == 100)
            #expect(window.recentUsage.costUSD == 1230 * factor)
            #expect(window.recentUsage.requests == 4 && window.recentUsage.cycleCount == 2)
            #expect(window.recentUsage.boundaryProrated)
            #expect(window.recentUsage.from == hour(1.0 / 3) && window.recentUsage.to == hour(25))
        }
        let beforeReset = try evaluate(points, records, at: 24.75)
        #expect(beforeReset.usedPercent == 40 && beforeReset.cycles.count == 1)
        #expect(beforeReset.recentUsage.status == .insufficientHistory && beforeReset.recentUsage.observedCostUSD == 730)
        #expect(beforeReset.recentUsage.costUSD == nil)
    }

    @Test func keepsExactProviderAccountAndDeviceCoverageWithoutInventingPrice() throws {
        let records = [
            request(0, 0, account: "different@example.test"), // retained ledger reaches window start
            request(1, 4, account: "ONE@EXAMPLE.TEST"),
            request(2, 10, device: "gateway", model: "unknown-price", agent: .cpa),
            request(2.25, 20, account: email, agent: .claudeCode, channel: "Claude"),
            request(2.5, 1000, account: email, login: "API Key", agent: .cpa),
            request(2.75, 500, model: "codex-auto-review"),
            request(3, 0, status: "429"),
            request(3.5, 1000), // outside last official sample
        ]
        let window = try evaluate([sample(3, 25)], records, at: 4)
        #expect(window.account == email && window.feeKey == "codex/" + email)
        #expect(window.observedCostUSD == 4 && window.estimatedFullUSD == 16 && window.estimatedRemainingUSD == 12)
        #expect(window.requests == 4 && window.unpricedRequests == 1 && window.excludedRequests == 2)
        #expect(window.currentCycle.pricedRequests == 1 && window.currentCycle.eligibleRequests == 2)
        #expect(window.currentCycle.pricingCoverage == 0.5)
        #expect(window.quality == [.unpriced])
        let mini = try #require(window.devices.first { $0.id == "mini" })
        let gateway = try #require(window.devices.first { $0.id == "gateway" })
        #expect(mini.name == "Example Mac" && mini.requests == 3 && mini.knownCostUSD == 4 && mini.priceShare == 1)
        #expect(gateway.name == "Example Gateway" && gateway.totalTokens == 20 && gateway.knownCostUSD == nil)
        #expect(window.fullUncertaintyUSD == 16.0 / 24 && window.remainingUncertaintyUSD == window.fullUncertaintyUSD)
        let share = try #require(window.currentCycle.feeShare(monthlyFee: 60))
        #expect(abs(share - 60 * 7 / 30.4375) < 1e-12)
        #expect(window.currentCycle.fullFeeRatio(monthlyFee: 60) == 16 / share)
        #expect(UsageQuotaInsights.estimateError(full: 4, usedPercent: 1) == .infinity)
        #expect(UsageQuotaInsights.estimateError(full: 0, usedPercent: 0.5) == 0)
    }

    @Test func modelCostSharesMatchAttributedDeviceCostsForEachObservedCycle() throws {
        var native = request(0.5, 5, model: "gpt-alias")
        native.sentModel = "gpt-fixture"
        var gateway = request(1, 1, device: "gateway", agent: .cpa)
        gateway.sentModel = "—"
        let alt = request(1.05, 2, model: "gpt-alt")
        let unpriced = request(1.1, 12, model: "gpt-unpriced")
        let failed = request(1.5, 2, model: "UNKNOWN-MODEL", status: "429")
        let unknown = request(1.6, 1, model: "—")
        let zero = request(1.65, 9, model: "zero-cost")
        let review = request(2, 3, model: "codex-auto-review")
        let current = request(25, 7, model: " gpt-new ")
        let records = [
            request(-1, 2, model: "before-start"),
            native, gateway, alt, unpriced, failed, unknown, zero,
            request(1.7, 10, model: "another-account", account: "other@example.test"),
            request(1.8, 10, model: "api-key-request", login: "API Key", agent: .cpa),
            request(1.9, 10, model: "another-channel", channel: "Claude"),
            request(1.95, 10, model: "unattributed", account: nil, creator: email),
            review,
            request(2.01, 10, model: "after-observation"),
            request(24, 2, device: "gateway", agent: .cpa),
            current,
            request(25.1, 10, model: "after-current-observation"),
        ]
        var costs = Dictionary(uniqueKeysWithValues: records.map { ($0.key, RequestCost.priced(1_000_000_000)) })
        costs[native.key] = .priced(3_000_000_000)
        costs[gateway.key] = .pricedWithCacheWriteFallback(1_000_000_000)
        costs[alt.key] = .priced(4_000_000_000)
        costs[unknown.key] = .priced(2_000_000_000)
        costs[zero.key] = .priced(0)
        costs[current.key] = .priced(7_000_000_000)
        costs[unpriced.key] = .unknown
        costs[failed.key] = .excluded
        costs[review.key] = .excluded
        let points = [sample(2, 100), sample(25, 50, start: 24)]
        let result = try evaluate(points, records, at: 26, costs: costs)
        let first = try #require(result.cycles.first)
        #expect(first.modelCosts.map(\.model) == ["gpt-alt", "gpt-fixture", "unknown"])
        #expect(first.modelCosts.map(\.costNanos) == [4_000_000_000, 4_000_000_000, 2_000_000_000])
        #expect(result.currentCycle.modelCosts.map(\.model) == ["gpt-new", "gpt-fixture"])
        #expect(result.currentCycle.modelCosts.map(\.costNanos) == [7_000_000_000, 1_000_000_000])
        for cycle in result.cycles {
            let modelUSD = Double(cycle.modelCosts.map(\.costNanos).reduce(0, +)) / 1_000_000_000
            #expect(modelUSD == cycle.observedCostUSD)
            #expect(modelUSD == cycle.devices.compactMap(\.knownCostUSD).reduce(0, +))
        }
    }

    @Test func doesNotPriceSessionCreatorOrBridgeAnUncertainOrCorrectedInterval() throws {
        let begin = request(0, 0, account: "different@example.test")
        let usable = request(1, 8, tier: "priority")
        let creator = request(2, 100, account: nil, creator: email)
        let uncertain = try evaluate([sample(3, 50)], [begin, usable, creator], at: 3)
        #expect(uncertain.requests == 1 && uncertain.observedCostUSD == 20)
        #expect(uncertain.estimatedFullUSD == 40 && uncertain.estimatedRemainingUSD == 20)
        #expect(uncertain.quality == [.partialHistory] && uncertain.currentCycle.coverageIncomplete)
        #expect(uncertain.unattributedRequests == 1 && uncertain.fullUncertaintyUSD == nil)
        let noKnown = try evaluate([sample(3, 50)], [begin, creator], at: 3)
        #expect(noKnown.requests == 0 && noKnown.estimatedFullUSD == nil)
        #expect(noKnown.currentCycle.modelCosts.isEmpty)
        #expect(uncertain.recentUsage.status == .insufficientHistory && uncertain.recentUsage.usedPercent == 50)
        #expect(uncertain.recentUsage.coverageIncomplete && uncertain.recentUsage.unattributedRequests == 1)
        #expect(uncertain.recentUsage.observedCostUSD == 20)
        let corrected = try evaluate([sample(1, 80), sample(2, 60), sample(3, 75)],
                                     [begin, usable, request(2.5, 3)], at: 3)
        #expect(corrected.cycles.count == 1)
        #expect(corrected.recentUsage.status == .partialHistory && corrected.recentUsage.usedPercent == 15)
        #expect(corrected.recentUsage.observedCostUSD == 3 && corrected.recentUsage.from == hour(2))
        let truncated = try evaluate([sample(1, 30), sample(3, 70)], [usable, request(2.5, 3)], at: 3)
        #expect(truncated.quality == [.partialHistory] && truncated.estimatedFullUSD == 23.0 / 0.7)
        #expect(truncated.unattributedRequests == 0 && truncated.currentCycle.coverageIncomplete)
        #expect(truncated.recentUsage.status == .insufficientHistory && truncated.recentUsage.usedPercent == 70)
        #expect(truncated.recentUsage.coverageIncomplete && truncated.recentUsage.observedCostUSD == 23)
    }

    @Test func confirmsOfficialHundredAcrossResetEvenWhenCostsArePartial() throws {
        let points = [sample(1, 100), sample(25, 89, start: 24)]
        let requests = [
            request(0, 0, account: "different@example.test"),
            request(0.5, 100),
            request(24.3, 200),
            request(24.4, 50, account: nil),
            request(24.6, 500, login: "api-key", agent: .cpa),
        ]
        let window = try evaluate(points, requests, at: 25)
        let recent = window.recentUsage
        #expect(window.cycles.map(\.usedPercent) == [100, 89])
        #expect(recent.status == .ready && recent.usedPercent == 100 && recent.cycleCount == 2)
        #expect(recent.costUSD == 211 && recent.unattributedRequests == 1 && recent.coverageIncomplete)
        #expect(recent.requests == 2 && recent.boundaryProrated)
    }

    @Test func handlesConflictingPeersAndUnavailableCycleBounds() throws {
        let shared = sample(1, 20)
        let windows = UsageQuotaInsights.evaluate(observations: [
            shared, shared, sample(2, 40), sample(2, 50), sample(2, 40),
            sample(3, 30, start: nil), sample(5, 55),
        ], requests: [request(0, 0, account: "different@example.test"), request(0.5, 3)], pricing: try engine(), at: hour(3))
        let window = try #require(windows.first)
        #expect(window.history.map(\.usedPercent) == [20, 30])
        #expect(window.quality == [.missingWindow, .partialHistory])
        #expect(window.observedCostUSD == nil && window.estimatedRemainingUSD == nil)
        #expect(!window.isActive && window.cycles.count == 1 && window.plottedCycles.count == 1)
        #expect(window.recentUsage.status == .partialHistory && window.recentUsage.costUSD == nil)
    }

    @Test func retainsConfirmedTimestampsAndResetBoundaryOwnership() throws {
        let points = [sample(1, 30), sample(2, 40), sample(3, 60, start: 2)]
        let records = [request(0, 1), request(1, 2), request(1.5, 3), request(2, 4), request(3, 5)]
        let window = try evaluate(points, records, at: 3)
        #expect(window.cycles.count == 2)
        #expect(window.cycles.first?.observedCostUSD == 10) // standalone earlier cycle includes its last sample
        #expect(window.cycles.last?.observedCostUSD == 9) // newer cycle also begins exactly here
        #expect(window.recentUsage.costUSD == 15) // shared boundary is counted exactly once in rolling sum
        #expect(window.recentUsage.requests == 5)
    }
}
