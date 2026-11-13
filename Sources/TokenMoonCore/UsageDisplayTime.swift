// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Presentation and bucketing only. Recorded instants and UTC sync shard keys never change.
public enum UsageDisplayTime {
    public static let system = "system"

    public static func timeZone(for identifier: String) -> TimeZone {
        if identifier != system, let zone = TimeZone(identifier: identifier) { return zone }
        return .autoupdatingCurrent
    }

    public static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    public static func format(_ date: Date, as style: Date.FormatStyle, calendar: Calendar) -> String {
        var style = style
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style.format(date)
    }

    public static func defaultHours(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let through = UsageBucketInterval.hour.interval(containing: now, calendar: calendar)?.start ?? now
        return from...through
    }
}
