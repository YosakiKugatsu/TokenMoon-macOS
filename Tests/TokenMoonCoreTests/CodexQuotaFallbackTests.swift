// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func liveCodexQuotaCanBeAttributedWithoutOnlineDiscoveryOnlyForTheSelectedWorkspace() throws {
    let selected = "12345678-1234-5678-1234-123456789abc"
    let other = "12345678-1234-5678-1234-123456789def"
    let payload = """
        {"activeSessionId":"signed-in","sessions":[
          {"sessionId":"signed-in","email":"person@example.test","isActive":true,
           "selectedWorkspaceAccountId":"\(selected)","workspaces":[{"accountId":"\(selected)"},{"accountId":"\(other)"}]},
          {"sessionId":"stored","email":"person@example.test","isActive":false,
           "selectedWorkspaceAccountId":"\(other)","workspaces":[{"accountId":"\(other)"}]}
        ]}
        """
    let sessions = try JSONDecoder().decode(CodexAccountSessionsReply.self, from: Data(payload.utf8))
    #expect(sessions.matchesActiveWorkspace(selected))
    #expect(!sessions.matchesActiveWorkspace(other))
    #expect(!sessions.matchesActiveWorkspace(nil))
    let conflicting = payload.replacingOccurrences(of: "\"activeSessionId\":\"signed-in\"", with: "\"activeSessionId\":\"stored\"")
    let inactive = try JSONDecoder().decode(CodexAccountSessionsReply.self, from: Data(conflicting.utf8))
    #expect(!inactive.matchesActiveWorkspace(other))
}

@Test func codexQuotaFallbackKeepsOnlyTheVerifiedWorkspacesCurrentCycle() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let prior = now.addingTimeInterval(-1_800)
    let reset = now.addingTimeInterval(86_400)
    let account = QuotaAccount(id: "codex:active", agent: .codex, displayName: "Codex", plan: "pro",
                               windows: [], note: "读取官方额度超时", accountEmail: "person@example.test")
    func row(_ workspace: String, email: String = "PERSON@example.test", window: String = "codex:primary:10080",
             observed: Date, reset: Date, used: Double) -> QuotaWireObservation {
        QuotaWireObservation(agent: .codex, account: email, windowID: "codex:\(workspace)/\(window)",
                             windowLabel: "7 天", observedAt: observed, usedPercent: used,
                             resetsAt: reset, durationSeconds: 604_800, plan: "pro")
    }
    let valid = row("active", observed: prior, reset: reset, used: 19)
    let unrelated = [
        row("other", observed: now, reset: reset, used: 99),
        row("active", email: "different@example.test", observed: now, reset: reset, used: 95),
        row("active", window: "model:primary:10080", observed: now.addingTimeInterval(-900), reset: now, used: 91),
        row("active", observed: now.addingTimeInterval(60), reset: reset, used: 50),
    ]
    #expect(NativeQuotaHistoryStore.lastKnownCodexAccount(account, from: unrelated, now: now) == nil)
    let recovered = try #require(NativeQuotaHistoryStore.lastKnownCodexAccount(
        account, from: unrelated + [valid], now: now
    ))
    #expect(recovered.windows.map(\.usedPercent) == [19])
    #expect(recovered.observedAt == prior)
    #expect(recovered.codexMainAllowance?.fiveHours == .unavailable)
    #expect(recovered.note == account.note)
    #expect(recovered.provenance == .lastKnown)
    #expect(NativeQuotaHistoryStore.liveSamples([recovered]).isEmpty)
}

@Test func codexQuotaFallbackMergesIndependentInMemoryAndArchivedWindowsWithoutResurrectingExpiredCycles() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let email = "person@example.test"
    let short = "codex:primary:300", week = "codex:secondary:10080", expired = "model:primary:300"
    let weekTime = now.addingTimeInterval(-1_400), shortTime = now.addingTimeInterval(-500)
    let active = QuotaAccount(id: "codex:active", agent: .codex, displayName: "Codex", plan: "plus", windows: [],
                              note: "官方接口暂不可用", accountEmail: email)
    func archive(_ id: String, _ used: Double, _ time: Date, _ reset: Date, _ duration: Double) -> QuotaWireObservation {
        QuotaWireObservation(agent: .codex, account: email, windowID: "\(active.id)/\(id)", windowLabel: id,
                             observedAt: time, usedPercent: used, resetsAt: reset, durationSeconds: duration, plan: "plus")
    }
    let shortReset = now.addingTimeInterval(1_000)
    let weekReset = now.addingTimeInterval(86_400)
    let rows = [archive(week, 30, weekTime, weekReset, 604_800),
                archive(short, 35, weekTime, shortReset, 18_000),
                archive(expired, 10, weekTime, shortReset, 18_000),
                archive(expired, 70, now.addingTimeInterval(-100), now, 18_000)]
    func previous(id: String, email: String, percent: Double) -> QuotaAccount {
        QuotaAccount(id: id, agent: .codex, displayName: "Codex", plan: "plus", windows: [
            .init(id: short, label: "5 小时", usedPercent: percent, resetsAt: shortReset, durationSeconds: 18_000),
        ], observedAt: shortTime, accountEmail: email)
    }
    let restored = try #require(NativeQuotaHistoryStore.lastKnownCodexAccount(
        active, from: rows, previous: previous(id: active.id, email: email, percent: 40), now: now
    ))
    let restoredShort = try #require(restored.windows.first { $0.id == short })
    let restoredWeek = try #require(restored.windows.first { $0.id == week })
    #expect(restored.windows.count == 2)
    #expect(restoredShort.usedPercent == 40)
    #expect(restoredWeek.usedPercent == 30)
    #expect(restored.observationTime(for: restoredShort) == shortTime)
    #expect(restored.observationTime(for: restoredWeek) == weekTime)
    #expect(restored.freshness(for: restoredShort, now: now) == .stale)
    #expect(restored.freshness(for: restoredShort, now: shortReset) == .resetPending)
    #expect(restored.freshness(for: restoredWeek, now: shortReset) == .stale)
    #expect(QuotaObservation(account: restored, window: restoredWeek) == nil)
    #expect(QuotaForecast.estimate(account: restored, window: restoredWeek, observations: [], now: now) == nil)

    for mismatched in [previous(id: "codex:other", email: email, percent: 99),
                       previous(id: active.id, email: "other@example.test", percent: 98)] {
        let onlyArchive = NativeQuotaHistoryStore.lastKnownCodexAccount(active, from: rows, previous: mismatched, now: now)
        #expect(onlyArchive?.windows.first { $0.id == short }?.usedPercent == 35)
    }

    let next = try #require(NativeQuotaHistoryStore.lastKnownCodexAccount(active, from: rows, previous: restored, now: shortReset))
    #expect(next.windows.map(\.id) == [week])
    #expect(next.observationTime(for: next.windows[0]) == weekTime)
}
