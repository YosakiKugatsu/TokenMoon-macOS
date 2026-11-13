// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Suite("Compatibility with Usage Insights complete-request accounting")
struct MetricsTests {
    private func row(
        _ id: String = "1", input: Int64 = 527, output: Int64 = 189, read: Int64 = 64_256,
        write: Int64 = 0, reasoning: Int64? = nil, ms: Double? = 5_500, source: String? = "test-complete-request",
        model: String = "gpt-test", sentModel: String? = nil, served: String? = nil, asked: String? = nil, status: String = "unknown"
    ) -> UsageRequest {
        UsageRequest(id: id, sessionID: "session", deviceID: "fixture", agent: .codex,
                     timestamp: Date(timeIntervalSince1970: 1_791_000_000), requestedModel: model, sentModel: sentModel,
                     serviceTier: served, requestedServiceTier: asked, status: status, durationMS: ms, timingSource: source,
                     inputTokens: input, outputTokens: output, cacheReadTokens: read, cacheWriteTokens: write, reasoningTokens: reasoning)
    }

    @Test func weightedCacheAndArithmeticRequestRates() {
        var metrics = UsageMetrics()
        let a = row(reasoning: 86)
        let b = row("2", input: 100, output: 50, read: 0, write: 50, ms: 1000)
        let c = row("3", input: 200, output: 300, read: 0, ms: 9000, source: nil)
        let d = row("4", input: 0, output: 5, read: 0, ms: 1, status: "503")
        for request in [a, b, c, d] { metrics.add(request, cost: .unknown) }
        #expect(a.totalTokens == 64_972)
        #expect(metrics.tokens == 65_677)
        #expect(metrics.cacheRate == 64_256.0 / (527 + 100 + 200 + 50 + 64_256))
        #expect(metrics.tpsSamples == 2)
        #expect(abs((metrics.tps ?? -1) - (189.0 / 5.5 + 50) / 2) < 0.000_000_1)
        #expect(metrics.requests == 4)
        #expect(metrics.cost == nil)
    }

    @Test func estimatedTPSUsesLoggedBoundariesIndependentlyOfCompleteTiming() {
        func estimate(_ id: String, output: Int64, interval: Double, status: String = "success") -> UsageRequest {
            var value = row(id, output: output, ms: nil, source: nil, status: status)
            value.estimatedDurationMS = interval
            value.estimatedTimingSource = "codex-session-log"
            return value
        }
        let short = estimate("short", output: 1_000, interval: 2_000)
        let long = estimate("long", output: 2_000, interval: 10_000)
        var exact = estimate("exact", output: 1_200, interval: 30_000)
        exact.agent = .cpa
        exact.durationMS = 2_000
        exact.timingSource = "native-full"
        var preciseOnly = exact
        preciseOnly.estimatedDurationMS = nil
        preciseOnly.estimatedTimingSource = nil
        let brief = estimate("brief", output: 999, interval: 1_000)
        let burst = estimate("burst", output: 2_000, interval: 999)
        let implausible = estimate("implausible", output: 20_000, interval: 1_000)
        let failed = estimate("failed", output: 1_000, interval: 2_000, status: "500")

        #expect(short.estimatedTPS == 500 && short.tps == nil)
        #expect(long.estimatedTPS == 200 && long.tps == nil)
        #expect(exact.tps == 600 && exact.estimatedTPS == 40 && exact.estimatedTPSElapsedMS == 30_000)
        #expect(preciseOnly.tps == 600 && preciseOnly.estimatedTPS == nil)
        #expect(brief.estimatedTPS == 999)
        #expect(burst.estimatedTPS == 2_000_000.0 / 999)
        #expect([implausible, failed].allSatisfy { $0.estimatedTPS == nil })

        var metrics = UsageMetrics()
        for request in [short, long, exact, brief, burst, implausible, failed] { metrics.add(request, cost: .unknown) }
        #expect(metrics.tpsSamples == 1 && metrics.tps == 600)
        #expect(metrics.estimatedTPSSamples == 3 && metrics.estimatedTPS == 100)
        #expect(metrics.requests == 7)
    }

    private func cpaRow(_ id: String, output: Int64, ms: Double, status: String = "success") -> UsageRequest {
        var request = row(id, output: output, ms: ms, source: "cpa-request-latency", status: status)
        request.agent = .cpa
        request.source = "cpa-gateway"
        return request
    }

    @Test func cpaEstimateUsesMeasuredFallbackWithoutRewritingTimingEvidence() throws {
        let gateway = cpaRow("gateway", output: 1_200, ms: 2_000)
        let timing = try #require(gateway.estimatedTPSTiming)
        #expect(gateway.estimatedTPS == 600 && gateway.tps == 600)
        #expect(timing.basis == .cpaCompleteRequestFallback && timing.source == "cpa-request-latency")
        #expect(gateway.estimatedDurationMS == nil && gateway.estimatedTimingSource == nil)

        var withLog = gateway
        withLog.estimatedDurationMS = 4_000
        withLog.estimatedTimingSource = "session-log"
        #expect(withLog.estimatedTPS == 300 && withLog.tps == 600)
        #expect(withLog.estimatedTPSTiming?.basis == .log)

        withLog.estimatedDurationMS = 100 // 12,000 tokens/s is outside the log estimate's valid range.
        #expect(withLog.estimatedTPSTiming?.basis == .cpaCompleteRequestFallback)
        #expect(withLog.estimatedDurationMS == 100 && withLog.estimatedTimingSource == "session-log")

        var desktop = gateway
        desktop.agent = .codex
        var otherSource = gateway
        otherSource.source = "other"
        var noProof = gateway
        noProof.timingSource = nil
        let failed = cpaRow("failed", output: 1_200, ms: 2_000, status: "503")
        let empty = cpaRow("empty", output: 0, ms: 2_000)
        #expect([desktop, otherSource, noProof, failed, empty].allSatisfy { $0.estimatedTPS == nil })

        var logOnly = withLog
        logOnly.estimatedDurationMS = 4_000
        logOnly.durationMS = nil
        logOnly.timingSource = nil
        #expect(logOnly.estimatedTPS == 300 && logOnly.tps == nil)
    }

    @Test func cpaFallbackRespectsEstimateAggregateFloorAfterSelectingTiming() {
        var logOnly = row("log", output: 1_000, ms: nil, source: nil)
        logOnly.estimatedDurationMS = 4_000
        logOnly.estimatedTimingSource = "codex-session-log"
        let fallback = cpaRow("gateway", output: 3_000, ms: 2_000)
        let shortOutput = cpaRow("short", output: 999, ms: 2_000)
        var shortLog = cpaRow("short-log", output: 2_000, ms: 2_000)
        shortLog.estimatedDurationMS = 500
        shortLog.estimatedTimingSource = "session-log"
        #expect(shortOutput.estimatedTPS == 499.5)
        #expect(shortLog.estimatedTPS == 4_000 && shortLog.estimatedTPSTiming?.basis == .log)

        var metrics = UsageMetrics()
        for request in [logOnly, fallback, shortOutput, shortLog] { metrics.add(request, cost: .unknown) }
        #expect(metrics.estimatedTPSSamples == 2 && metrics.estimatedTPSFallbackSamples == 1)
        #expect(metrics.estimatedTPS == 4_000_000.0 / 6_000)
        #expect(metrics.tpsSamples == 3)
    }

    @Test func dashboardEstimatedTPSScopesUseStrictOutputBoundaryAndWeightedTiming() {
        func logged(_ id: String, output: Int64, elapsed: Double, status: String = "success") -> UsageRequest {
            var request = row(id, output: output, ms: nil, source: nil, status: status)
            request.estimatedDurationMS = elapsed
            request.estimatedTimingSource = "codex-session-log"
            return request
        }
        let exactBoundary = cpaRow("800", output: 800, ms: 2_000)
        let firstIncluded = cpaRow("801", output: 801, ms: 3_000)
        let belowLegacy = logged("999", output: 999, elapsed: 1_000)
        let legacy = logged("1000", output: 1_000, elapsed: 4_000)
        let tooShort = logged("short", output: 2_000, elapsed: 999)
        let failed = logged("failed", output: 2_000, elapsed: 1_000, status: "503")
        let empty = logged("empty", output: 0, elapsed: 1_000)

        var metrics = UsageMetrics()
        metrics.add(exactBoundary, cost: .unknown)
        #expect(metrics.estimatedTPS(for: .over800) == nil)
        #expect(metrics.estimatedTPSSamples(for: .over800) == 0)
        #expect(metrics.estimatedTPS(for: .all) == 400)
        for request in [firstIncluded, belowLegacy, legacy, tooShort, failed, empty] {
            metrics.add(request, cost: .unknown)
        }

        // 800 enters only .all; both 801 and 999 enter the new filter but not
        // the legacy aggregate. Numerators/denominators are summed, not averaged.
        #expect(metrics.estimatedTPS(for: .all) == 3_600_000.0 / 10_000)
        #expect(metrics.estimatedTPS(for: .over800) == 2_800_000.0 / 8_000)
        #expect(metrics.estimatedTPSSamples(for: .all) == 4)
        #expect(metrics.estimatedTPSSamples(for: .over800) == 3)
        #expect(metrics.estimatedTPSFallbackSamples(for: .all) == 2)
        #expect(metrics.estimatedTPSFallbackSamples(for: .over800) == 1)
        #expect(metrics.estimatedTPS == 250 && metrics.estimatedTPSSamples == 1)
        #expect(metrics.estimatedTPSFallbackSamples == 0 && metrics.requests == 7)
    }

    @Test func priceCoverageThresholdAndReturnedTierPriority() throws {
        let data = Data("""
          {"model_prices":[
            {"model":"gpt-test","prompt_price_per_1m":1,"completion_price_per_1m":5,
             "cache_read_price_per_1m":0.1,"cache_write_price_per_1m":1.25,"price_multiplier":2,
             "tiers":[{"min_prompt_tokens":100,"prompt_price_per_1m":2}]},
            {"model":"gpt-alias","prompt_price_per_1m":10,"completion_price_per_1m":20,
             "price_multiplier":1}
          ]}
          """.utf8)
        let prices = try PricingEngine(book: PriceBook.decode(data, as: .omc), fastMultiplier: 2.5, ultraFastMultiplier: 4)
        // Context threshold counts 90 uncached + 10 cache reads. Exact requested model wins.
        let base: Int64 = 372_000
        #expect(prices.cost(row(input: 90, output: 1, read: 10, sentModel: "gpt-alias", served: "default", asked: "priority")) == .priced(base))
        #expect(prices.cost(row(input: 90, output: 1, read: 10, sentModel: "gpt-alias", served: "auto", asked: "priority")) == .priced(base * 5 / 2))
        #expect(prices.cost(row(input: 90, output: 1, read: 10, served: "ultra-fast", asked: "priority")) == .priced(base * 4))
        #expect(prices.cost(row(input: 0, output: 1, read: 1, model: "gpt-alias")) == .unknown)
        #expect(prices.cost(row(model: "missing", sentModel: "codex-auto-review")) == .excluded)
    }

    @Test func unpricedModelsDoNotContributeToCostOrPricingCoverage() throws {
        let data = Data(#"{"prices":[{"model":"gpt-test","input":1,"output":2}]}"#.utf8)
        let prices = try PricingEngine(book: PriceBook.decode(data, as: .publicCatalog))
        let unpriced = row(input: 5, output: 2, read: 0, model: "missing")
        let unpricedEmpty = row(input: 0, output: 0, read: 0, model: "missing")
        let priced = row(input: 1_000_000, output: 1_000_000, read: 0)
        #expect(prices.cost(row(input: 0, output: 0, read: 0)) == .priced(0))
        var metrics = UsageMetrics()
        for request in [unpriced, unpricedEmpty] { metrics.add(request, cost: prices.cost(request)) }
        #expect(metrics.cost == nil && metrics.unpricedRequests == 2 && metrics.pricedRequests == 0)
        metrics.add(priced, cost: prices.cost(priced))
        #expect(metrics.cost == 3 && metrics.unpricedRequests == 2 && metrics.pricedRequests == 1)
        #expect(metrics.tokens == 2_000_007 && metrics.requests == 3)
    }

    @Test func publicPricebookAndNanosRoundBeforeFast() throws {
        let data = Data("""
          {"prices":[{"model":"gpt-test","input":0.0005,"output":3,
            "tiers":[{"min_prompt_tokens":500000,"input":0.01}]}]}
          """.utf8)
        let engine = try PricingEngine(book: PriceBook.decode(data, as: .publicCatalog))
        // 0.5 nanos rounds to 1; Fast projection turns that 1 into 3 nanos.
        #expect(engine.cost(row(input: 1, output: 0, read: 0, asked: "priority")) == .priced(3))
        #expect(try PriceBook.bundledPublic().count > 20)
    }
}
