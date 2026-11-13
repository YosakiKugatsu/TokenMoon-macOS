// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Short time labels for status lines. Callers pass the display
// calendar, whose time zone decides the clock; units are spelled out so the wording
// doesn't depend on the process locale.

/// "刚刚", "3 分钟前", "2 小时前", "4 天前".
func relativeAgeLabel(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "刚刚"
    case ..<3600: return "\(Int(seconds / 60)) 分钟前"
    case ..<86_400: return "\(Int(seconds / 3600)) 小时前"
    default: return "\(Int(seconds / 86_400)) 天前"
    }
}

/// "刚刚更新", "3 分钟前更新".
func updatedAgeLabel(_ date: Date, now: Date = .now) -> String {
    relativeAgeLabel(date, now: now) + "更新"
}

/// "14:32" on the same day, otherwise "11月9日 14:32".
func statusClockLabel(_ date: Date, now: Date = .now, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    guard !calendar.isDate(date, inSameDayAs: now) else { return clock }
    return "\(parts.month ?? 0)月\(parts.day ?? 0)日 " + clock
}
