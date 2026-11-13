// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct CodexAllowanceTests {
    private let short = QuotaWindow(id: "codex:primary:300", label: "5 小时", usedPercent: 50,
                                    durationSeconds: 5 * 3600)
    private let week = QuotaWindow(id: "codex:secondary:10080", label: "7 天", usedPercent: 72,
                                   durationSeconds: 7 * 86400)

    private func account(plan: String, windows: [QuotaWindow], agent: Agent = .codex) -> QuotaAccount {
        QuotaAccount(id: "test", agent: agent, displayName: "Test", plan: plan, windows: windows)
    }

    @Test func proOnlyFillsUnreportedShortAllowanceWhenStandardWeeklyReadingIsKnown() {
        let pro = account(plan: "pro", windows: [week])
        #expect(pro.codexMainAllowance?.fiveHours == .unlimited)
        #expect(pro.codexMainAllowance?.sevenDays == .reported(week))
        #expect(pro.windows == [week])
        #expect(pro.plan == "pro")
        #expect(pro.planDisplayName == "Pro")
        #expect(account(plan: "pro", windows: [short, week]).codexMainAllowance?.fiveHours == .reported(short))

        let unfamiliar = QuotaWindow(id: "codex:primary:0", label: "主要额度", usedPercent: 12)
        #expect(account(plan: "promax", windows: [unfamiliar, week]).codexMainAllowance?.fiveHours == .unavailable)
        let modelSpecific = QuotaWindow(id: "codex_model:primary:10080", label: "模型 · 7 天", usedPercent: 5,
                                            durationSeconds: 7 * 86400)
        #expect(account(plan: "pro", windows: [modelSpecific]).codexMainAllowance == nil)
    }

    @Test func plusAndClaudeDoNotInheritCodexProShortAllowance() {
        let plus = account(plan: "plus", windows: [short, week])
        #expect(plus.codexMainAllowance?.fiveHours == .reported(short))
        #expect(plus.codexMainAllowance?.sevenDays == .reported(week))
        #expect(account(plan: "plus", windows: [week]).codexMainAllowance?.fiveHours == .unavailable)
        #expect(account(plan: "unknown", windows: [week]).codexMainAllowance == nil)
        let claude = account(plan: "pro", windows: [week], agent: .claudeCode)
        #expect(claude.planDisplayName == "Pro")
        #expect(claude.codexMainAllowance == nil)
    }
}
