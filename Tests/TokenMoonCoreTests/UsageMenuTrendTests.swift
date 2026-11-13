// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func menuTrendUsesSixEqualElapsedBucketsAcrossFallBack() throws {
    let now = try Date.ISO8601FormatStyle().parse("2026-11-01T12:01:00Z")
    let trend = UsageMenuTrend(now: now)
    #expect(trend.bounds.upperBound.timeIntervalSince(trend.bounds.lowerBound) == 86_400)
    let samples = (0..<6).map { trend.bounds.lowerBound.addingTimeInterval(Double($0 * 14_400)) }
    #expect(samples.compactMap(trend.index(of:)) == [0, 1, 2, 3, 4, 5])
    #expect(trend.index(of: trend.bounds.lowerBound.addingTimeInterval(-1)) == nil)
    #expect(trend.index(of: now) == nil)
    let recent = now.addingTimeInterval(-3600)
    let change = trend.nextChange(for: recent, index: try #require(trend.index(of: recent)))
    #expect(change.timeIntervalSince(now) == 10_800)
    #expect(UsageMenuTrend(now: change.addingTimeInterval(1)).index(of: recent) == 4)
}
