// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum UsageBucketInterval: Equatable, Sendable {
    case hour, hours(Int), day, days(Int), week, month, quarter, year

    public static let defaultTargetBucketCount = 28

    public var isSubdaily: Bool {
        switch self {
        case .hour, .hours: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .hour: "按小时"
        case let .hours(count): "每 \(count) 小时"
        case .day: "按天"
        case let .days(count): "每 \(count) 天"
        case .week: "按周"
        case .month: "按月"
        case .quarter: "按季度"
        case .year: "按年"
        }
    }

    public static func recommended(for span: ClosedRange<Date>, calendar: Calendar,
                                   targetBucketCount: Int = defaultTargetBucketCount) -> Self {
        // Range ÷ resolution gives a nominal step. Round it to a useful clock
        // or calendar interval. Slight slack avoids doubling the step for one
        // partial boundary or a longer daylight-saving transition day.
        let target = Double(min(120, max(4, targetBucketCount)))
        let nominal = span.upperBound.timeIntervalSince(span.lowerBound) / target
        let start = span.lowerBound
        func seconds(_ component: Calendar.Component, _ count: Int, fallback: Double) -> Double {
            calendar.date(byAdding: component, value: count, to: start)?
                .timeIntervalSince(start) ?? fallback
        }
        let day = 86_400.0
        let steps: [(Self, Double)] = [
            (.hour, 3600), (.hours(2), 7200), (.hours(3), 10_800), (.hours(6), 21_600), (.hours(12), 43_200),
            (.day, day), (.days(2), 2 * day), (.days(3), 3 * day), (.week, 7 * day), (.days(14), 14 * day),
            (.month, seconds(.month, 1, fallback: 30 * day)),
            (.quarter, seconds(.month, 3, fallback: 90 * day)),
            (.year, seconds(.year, 1, fallback: 365 * day)),
        ]
        return steps.first { nominal <= $0.1 * 1.08 }?.0 ?? .year
    }

    public func interval(containing date: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .hour: Self.localHours(on: date, calendar: calendar).first { $0.start <= date && date < $0.end }
        case let .hours(count):
            Self.localHourGroups(on: date, calendar: calendar, width: count)
                .first { $0.start <= date && date < $0.end }
        case .day: calendar.dateInterval(of: .day, for: date)
        case let .days(count): Self.localDayGroup(containing: date, calendar: calendar, width: count)
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)
        case .month: calendar.dateInterval(of: .month, for: date)
        case .quarter: calendar.dateInterval(of: .quarter, for: date)
        case .year: calendar.dateInterval(of: .year, for: date)
        }
    }

    /// Walk civil hour boundaries, preserving both occurrences of a repeated hour and
    /// excluding nonexistent times. A partial hour at an offset transition is its own interval.
    public static func localHours(on date: Date, calendar: Calendar) -> [DateInterval] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        var cursor = day.start
        var hours: [DateInterval] = []
        var nextTransition = calendar.timeZone.nextDaylightSavingTimeTransition(after: cursor)
        while cursor < day.end {
            let components = calendar.dateComponents([.minute, .second], from: cursor)
            let elapsed = (components.minute ?? 0) * 60 + (components.second ?? 0)
            var next = min(day.end, cursor.addingTimeInterval(Double(3600 - elapsed)))
            if let transition = nextTransition, transition > cursor, transition <= next {
                next = transition
                nextTransition = calendar.timeZone.nextDaylightSavingTimeTransition(after: transition)
            }
            guard next > cursor else { break }
            hours.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return hours
    }

    /// Group adjacent real hours by their wall-clock interval. A repeated
    /// hour contributes to the same group and a skipped hour adds no time.
    private static func localHourGroups(on date: Date, calendar: Calendar, width: Int) -> [DateInterval] {
        let width = min(23, max(1, width))
        let hours = localHours(on: date, calendar: calendar)
        guard width > 1 else { return hours }
        var previousGroup: Int?
        var groups: [DateInterval] = []
        for hour in hours {
            let group = calendar.component(.hour, from: hour.start) / width
            if previousGroup == group, let last = groups.last, last.end == hour.start {
                groups[groups.count - 1] = DateInterval(start: last.start, end: hour.end)
            } else {
                groups.append(hour)
            }
            previousGroup = group
        }
        return groups
    }

    /// Anchor multi-day steps to a fixed civil Monday, independent of the
    /// visible range and of time-zone offset transitions during the interval.
    private static func localDayGroup(containing date: Date, calendar: Calendar, width: Int) -> DateInterval? {
        let width = min(365, max(1, width))
        let day = calendar.startOfDay(for: date)
        guard let epoch = calendar.date(from: DateComponents(year: 1970, month: 1, day: 5)),
              let ordinal = calendar.ordinality(of: .day, in: .era, for: day),
              let anchorOrdinal = calendar.ordinality(of: .day, in: .era, for: epoch) else { return nil }
        let days = ordinal - anchorOrdinal
        let remainder = (days % width + width) % width
        guard let first = calendar.date(byAdding: .day, value: -remainder, to: day) else { return nil }
        let start = calendar.startOfDay(for: first)
        guard let after = calendar.date(byAdding: .day, value: width, to: start) else { return nil }
        let end = calendar.startOfDay(for: after)
        guard start <= date, date < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    func buckets(in bounds: Range<Date>, calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        var cursor = bounds.lowerBound
        while cursor < bounds.upperBound && result.count < 1500 {
            if isSubdaily, let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor {
                let width = if case let .hours(count) = self { count } else { 1 }
                let groups = Self.localHourGroups(on: cursor, calendar: calendar, width: width)
                    .filter { $0.end > cursor && $0.start < bounds.upperBound }
                result += groups.prefix(1500 - result.count)
                cursor = day.end
            } else if let bucket = interval(containing: cursor, calendar: calendar), bucket.end > cursor {
                result.append(bucket)
                cursor = bucket.end
            } else {
                break
            }
        }
        return result
    }
}
