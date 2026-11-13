// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import TokenMoonCore

enum MenuBarDisplayMode: String, CaseIterable {
    case usage, quota, icon

    var label: String {
        switch self {
        case .usage: "Token / Cost"
        case .quota: "订阅额度"
        case .icon: "仅图标"
        }
    }
}

enum MenuBarQuotaSource: String, CaseIterable {
    case automatic, codex, claude, antigravity

    var label: String {
        switch self {
        case .automatic: "自动（优先 Codex）"
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        }
    }

    fileprivate var agents: [Agent] {
        switch self {
        case .automatic: [.codex, .claudeCode, .claudeDesktop, .antigravity]
        case .codex: [.codex]
        case .claude: [.claudeCode, .claudeDesktop]
        case .antigravity: [.antigravity]
        }
    }
}

struct MenuBarQuotaPresentation {
    let metrics: [MoonStatusGlyph.Metric]
    let accessibilityLabel: String

    init(accounts: [QuotaAccount], source: MenuBarQuotaSource, isRefreshing: Bool, now: Date) {
        let options = source.agents.flatMap { agent in
            accounts.filter { $0.agent == agent }.map { account in
                (account, Self.readings(for: account, now: now))
            }
        }
        guard let (account, readings) = options.first(where: { !$0.0.windows.isEmpty }) ?? options.first else {
            metrics = [.init(title: source == .automatic ? "Quota" : source.label, value: "—")]
            accessibilityLabel = isRefreshing ? "TokenMoon, refreshing subscription allowance"
                : "TokenMoon, \(source == .automatic ? "subscription" : source.label) allowance unavailable"
            return
        }
        let freshness = account.freshness(now: now)
        let dimmed = freshness == .cached || freshness == .stale
        metrics = readings.map { .init(title: $0.title, value: $0.percent ?? "—", isDimmed: dimmed) }
        let provider = account.agent == .claudeCode || account.agent == .claudeDesktop ? "Claude" : account.agent.label
        let name = [provider, account.planDisplayName].compactMap { $0 }.joined(separator: " ")
        let spoken = readings.map {
            "\($0.details): \($0.percent ?? "unavailable")" + ($0.unlimited ? " (no separate limit)" : "")
        }.joined(separator: ", ")
        let qualifier = freshness == .cached ? " (client cache)" : dimmed ? " (last known)" : ""
        accessibilityLabel = "TokenMoon, \(name) remaining allowance\(qualifier), \(spoken)"
    }

    private struct Reading {
        let title: String
        let details: String
        let remaining: Double?
        var unlimited = false

        var percent: String? {
            remaining.map { $0.formatted(.number.precision(.fractionLength(0...1))
                .locale(Locale(identifier: "en_US"))) + "%" }
        }
    }

    private static func readings(for account: QuotaAccount, now: Date) -> [Reading] {
        func remaining(_ window: QuotaWindow?) -> Double? {
            guard let window, window.resetsAt.map({ $0 > now }) ?? true else { return nil }
            return window.remainingPercent
        }
        func reported(_ reading: CodexMainAllowance.Reading) -> Double? {
            if case let .reported(window) = reading { return remaining(window) }
            return nil
        }
        func pair(_ provider: String, short: Double?, week: Double?, unlimited: Bool = false) -> [Reading] {
            [.init(title: "\(provider) 5h", details: "5 hours", remaining: short, unlimited: unlimited),
             .init(title: "\(provider) 7d", details: "7 days", remaining: week)]
        }
        switch account.agent {
        case .codex:
            if let allowance = account.codexMainAllowance {
                let week = reported(allowance.sevenDays)
                let unlimited = allowance.fiveHours == .unlimited && week != nil
                return pair("Codex", short: unlimited ? 100 : reported(allowance.fiveHours), week: week, unlimited: unlimited)
            }
            let standard = account.windows.filter { $0.id.hasPrefix("codex:") }
            let short = standard.first { $0.durationSeconds == 5 * 3600 }
            let week = standard.first { $0.durationSeconds == 7 * 86400 }
            if short != nil || week != nil { return pair("Codex", short: remaining(short), week: remaining(week)) }
        case .claudeCode, .claudeDesktop:
            let short = account.windows.first { $0.id == "session" }
            let week = account.windows.first { $0.id == "week" }
            if short != nil || week != nil { return pair("Claude", short: remaining(short), week: remaining(week)) }
        case .antigravity, .cpa:
            break
        }
        // A provider with only model-specific meters gets one clearly marked
        // lowest reading. Its full model/window name remains in the tooltip.
        let provider: String = switch account.agent {
        case .codex: "Codex"
        case .claudeCode, .claudeDesktop: "Claude"
        case .antigravity: "AG"
        case .cpa: "CPA"
        }
        guard let lowest = account.windows.compactMap({ window in
            remaining(window).map { (window, $0) }
        }).min(by: { ($0.1, $0.0.id) < ($1.1, $1.0.id) }) else {
            return [.init(title: "\(provider) Quota", details: "quota", remaining: nil)]
        }
        return [.init(title: "\(provider) Min", details: lowest.0.label, remaining: lowest.1)]
    }
}
