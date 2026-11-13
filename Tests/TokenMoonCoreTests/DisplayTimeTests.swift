// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func displayZoneChangesTodayAndRenderedDatesWithoutChangingTheInstant() throws {
    let instant = try Date.ISO8601FormatStyle().parse("2026-11-10T01:15:00Z")
    let chicago = UsageDisplayTime.calendar(in: try #require(TimeZone(identifier: "America/Chicago")))
    let shanghai = UsageDisplayTime.calendar(in: try #require(TimeZone(identifier: "Asia/Shanghai")))
    let chicagoDay = UsageBucketInterval.day.interval(containing: instant, calendar: chicago)
    let shanghaiDay = UsageBucketInterval.day.interval(containing: instant, calendar: shanghai)
    #expect(chicago.component(.day, from: instant) == 9)
    #expect(shanghai.component(.day, from: instant) == 10)
    #expect(chicagoDay?.start == (try Date.ISO8601FormatStyle().parse("2026-11-09T06:00:00Z")))
    #expect(shanghaiDay?.start == (try Date.ISO8601FormatStyle().parse("2026-11-09T16:00:00Z")))
    let style = Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "en_US"))
    #expect(UsageDisplayTime.format(instant, as: style, calendar: chicago).hasSuffix("/09"))
    #expect(UsageDisplayTime.format(instant, as: style, calendar: shanghai).hasSuffix("/10"))
    let midnight = try Date.ISO8601FormatStyle().parse("2026-11-10T16:04:00Z")
    let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))
    #expect(UsageDisplayTime.format(midnight, as: clock, calendar: shanghai) == "00:04:00")
}

@Test func customHoursFollowTheSelectedZoneWithNonHourOffsets() throws {
    let now = try Date.ISO8601FormatStyle().parse("2026-11-10T01:10:00Z")
    let calendar = UsageDisplayTime.calendar(in: try #require(TimeZone(identifier: "Asia/Kathmandu")))
    let hours = UsageDisplayTime.defaultHours(now: now, calendar: calendar)
    #expect(calendar.component(.minute, from: hours.upperBound) == 0)
    #expect(hours.upperBound == (try Date.ISO8601FormatStyle().parse("2026-11-10T00:15:00Z")))
    let bounds = UsageRange.custom.bounds(now: now, customStart: hours.upperBound, customEnd: hours.upperBound, calendar: calendar)
    #expect(bounds.contains(now))
    #expect(bounds.upperBound.timeIntervalSince(bounds.lowerBound) == 3_600)
}
