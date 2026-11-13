// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func cacheAutoAxisZoomsWithoutLeavingPhysicalBounds() {
    let rates = [0.982, 0.988, 0.991]
    let zoom = RateChartScale.make(.cacheRate, values: rates, automatic: true)
    #expect(rates.allSatisfy(zoom.domain.contains))
    #expect(zoom.domain.lowerBound > 0.94 && zoom.domain.upperBound <= 1)
    #expect(zoom.ticks == zoom.ticks.sorted() && Set(zoom.ticks).count == zoom.ticks.count)
    #expect(RateChartScale.make(.cacheRate, values: rates, automatic: false).domain == 0...1)
    for exact in [0.0, 1.0] {
        let flat = RateChartScale.make(.cacheRate, values: [exact, .nan, .infinity], automatic: true)
        #expect(flat.domain.contains(exact))
        #expect(flat.domain.upperBound - flat.domain.lowerBound >= 0.02 - 1e-9)
        #expect(flat.ticks.allSatisfy { (0...1).contains($0) })
    }
}

@Test func throughputAutoAxisRetainsOutliersAndRespectsZeroBaselineMode() {
    let nearby = [58.3, 60.2, 61.1]
    let tight = RateChartScale.make(.throughput, values: nearby, automatic: true)
    #expect(tight.domain.lowerBound > 50 && nearby.allSatisfy(tight.domain.contains))
    let outlier = RateChartScale.make(.throughput, values: nearby + [240], automatic: true)
    #expect(outlier.domain.contains(240) && nearby.allSatisfy(outlier.domain.contains))
    let zero = RateChartScale.make(.throughput, values: nearby + [240], automatic: false)
    #expect(zero.domain.lowerBound == 0 && zero.domain.upperBound >= 240)
    #expect(RateChartScale.make(.throughput, values: [0], automatic: true).domain.contains(0))
}
