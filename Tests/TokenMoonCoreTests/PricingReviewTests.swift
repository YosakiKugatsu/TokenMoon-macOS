// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct PricingReviewTests {
    private func row(model: String, write: Int64 = 1_000, oneHour: Int64? = 600,
                     short: Int64? = 400, requestedTier: String? = nil) -> UsageRequest {
        UsageRequest(id: "request", sessionID: "session", deviceID: "fixture", agent: .claudeCode,
                     timestamp: Date(timeIntervalSince1970: 1_794_320_000),
                     requestedModel: model, requestedServiceTier: requestedTier, inputTokens: 0, outputTokens: 0,
                     cacheWriteTokens: write, cacheWrite5mTokens: short, cacheWrite1hTokens: oneHour)
    }

    @Test func oneHourWritesUseExplicitRateOrReportGenericFallback() throws {
        let data = Data("""
            {"prices":[
              {"model":"claude-split","input":1,"output":2,"cache_write":2,"cache_write_1h":4},
              {"model":"claude-flat","input":1,"output":2,"cache_write":2},
              {"model":"claude-tier","input":1,"output":2,"cache_write":2,"cache_write_1h":4,
               "tiers":[{"min_prompt_tokens":1000,"cache_write":5}]}
            ]}
            """.utf8)
        let pricing = try PricingEngine(book: PriceBook.decode(data, as: .publicCatalog))
        #expect(pricing.cost(row(model: "claude-split")) == .priced(3_200_000))
        let flat = row(model: "claude-flat")
        let fallback = pricing.cost(flat)
        #expect(fallback == .pricedWithCacheWriteFallback(2_000_000))
        #expect(pricing.cost(row(model: "claude-tier")) == .pricedWithCacheWriteFallback(5_000_000))
        #expect(pricing.cost(row(model: "claude-split", oneHour: 1_001)) == .pricedWithCacheWriteFallback(2_000_000))
        var usage = UsageMetrics()
        usage.add(flat, cost: fallback)
        #expect(usage.pricedRequests == 1 && usage.cacheWriteFallbackRequests == 1 && usage.cost == 0.002)
    }

    @Test func fastOverrideDoesNotChangeOtherChannelsOrUltraFast() throws {
        let data = Data("""
            {"model_prices":[
              {"model":"claude-opus","cache_write_price_per_1m":2,"cache_write_1h_price_per_1m":4,"price_multiplier":1},
              {"model":"gpt-example","cache_write_price_per_1m":2,"cache_write_1h_price_per_1m":4,"price_multiplier":1}
            ]}
            """.utf8)
        let pricing = try PricingEngine(book: PriceBook.decode(data, as: .omc), fastMultiplier: 2.5,
                                        ultraFastMultiplier: 4, fastMultipliersByChannel: ["Claude": 2, "GPT / Codex": -1])
        #expect(pricing.cost(row(model: "claude-opus", requestedTier: "fast")) == .priced(6_400_000))
        #expect(pricing.cost(row(model: "gpt-example", requestedTier: "fast")) == .priced(8_000_000))
        #expect(pricing.cost(row(model: "claude-opus", requestedTier: "ultrafast")) == .priced(12_800_000))
    }
}
