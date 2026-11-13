// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func popupTrendKeepsAStableClockKeyAndClipsBothEnds() throws {
    let now = try Date.ISO8601FormatStyle().parse("2026-11-10T10:24:00Z")
    let calendar = UsageDisplayTime.calendar(in: TimeZone(secondsFromGMT: 0)!)
    let window = UsageMiniTrendWindow(now: now, calendar: calendar)
    let nextMinute = UsageMiniTrendWindow(now: now.addingTimeInterval(60), calendar: calendar)
    #expect(window.cells.count == 25)
    #expect(window.cells.map(\.id) == nextMinute.cells.map(\.id))
    #expect(window.cells.first?.bounds.lowerBound == now.addingTimeInterval(-86_400))
    #expect(window.cells.last?.bounds.upperBound == now)
    #expect(window.cellIndex(containing: window.bounds.lowerBound) == 0)
    #expect(window.cellIndex(containing: now) == nil)
    let nextStart = try #require(window.cells.dropFirst().first).bounds.lowerBound
    #expect(window.cellIndex(containing: nextStart) == 1)
    #expect(window.nextGridChange == (try Date.ISO8601FormatStyle().parse("2026-11-10T11:00:00Z")))
    #expect(window.cells.dropFirst().dropLast().allSatisfy {
        $0.bounds.upperBound.timeIntervalSince($0.bounds.lowerBound) == 3600
    })
}

@Test func popupTrendPartitionsActualTwentyFourHoursAcrossDST() throws {
    let now = try Date.ISO8601FormatStyle().parse("2026-11-01T12:17:00Z")
    let calendar = UsageDisplayTime.calendar(in: TimeZone(identifier: "America/New_York")!)
    let window = UsageMiniTrendWindow(now: now, calendar: calendar)
    let cells = window.cells
    #expect(cells.reduce(0) { $0 + $1.bounds.upperBound.timeIntervalSince($1.bounds.lowerBound) } == 86_400)
    #expect(zip(cells, cells.dropFirst()).allSatisfy { $0.bounds.upperBound == $1.bounds.lowerBound })
    let firstRepeated = try Date.ISO8601FormatStyle().parse("2026-11-01T05:30:00Z")
    let secondRepeated = firstRepeated.addingTimeInterval(3600)
    let firstIndex = try #require(window.cellIndex(containing: firstRepeated))
    #expect(window.cellIndex(containing: secondRepeated) == firstIndex + 1)
}
