// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func theSameSevenDayRangeGetsFinerBucketsInWiderCharts() {
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    let range = first...first.addingTimeInterval(7 * 86_400)
    let calendar = UsageDisplayTime.calendar(in: TimeZone(secondsFromGMT: 0)!)
    let examples: [(width: Double, step: UsageBucketInterval)] = [
        (500, .hours(12)), (780, .hours(6)), (1_120, .hours(3)),
    ]
    for example in examples {
        let target = UsageChartResolution.targetBucketCount(forContentWidth: example.width)
        #expect(UsageBucketInterval.recommended(for: range, calendar: calendar, targetBucketCount: target) == example.step)
    }
    #expect(UsageChartResolution.targetBucketCount(forContentWidth: 780)
            == UsageChartResolution.targetBucketCount(forContentWidth: 785))
}
