// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func nativeClaudeUsageDistinguishesWindowsAndInterpretsProviderTimeZone() {
    let iso = ISO8601DateFormatter()
    let now = iso.date(from: "2026-11-10T15:00:00Z")!
    let report = """
        Current session: 85% used · resets Nov 10 at 12:50pm (America/Chicago)
        Current week (all models): 7% used · resets Nov 16, 12am (America/Chicago)
        Current week (Fable): 0% used
        Current week (Sonnet only): 25.5% used · resets Nov 13 at 10am (America/Chicago)
        Current week (all models): 99% used
        Current week (invalid): 140% used
        """
    let windows = ClaudeQuota.parseUsage(report, now: now)
    #expect(windows.map(\.id) == ["session", "week", "week:fable", "week:sonnet"])
    #expect(windows.first?.usedPercent == 85)
    #expect(windows.first?.resetsAt == iso.date(from: "2026-11-10T18:50:00Z"))
    #expect(windows.first(where: { $0.id == "week" })?.resetsAt == iso.date(from: "2026-11-16T06:00:00Z"))
    #expect(windows.first(where: { $0.id == "week:fable" })?.resetsAt == nil)
}

@Test func antigravityUsesOnlyAnActualNativeQuotaReport() {
    let now = ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!
    let report = """
        {"status":"SUCCESS","num_turns":0,"usage":{"total_tokens":0},"command":{"name":"usage","data":{
        "groups":[{"name":"Gemini Models","buckets":[
        {"id":"gemini-week","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-11-16T10:00:00.000Z"},
        {"id":"gemini-unavailable","window":"5h","remaining_fraction":1,"disabled":true},
        {"id":"gemini-unknown","window":"5h"}]}]}}}
        """
    let quota = AntigravityQuota.parseUsage(Data(report.utf8), now: now)
    #expect(quota.map(\.id) == ["gemini-week"])
    #expect(quota.first?.usedPercent == 25)
    #expect(quota.first?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-16T10:00:00Z"))
    #expect(AntigravityQuota.parseUsage(Data(report.replacingOccurrences(of: #""total_tokens":0"#, with: #""total_tokens":1"#).utf8), now: now).isEmpty)
    #expect(AntigravityQuota.supportsPrintUsage("Antigravity 1.1.11"))
    #expect(!AntigravityQuota.supportsPrintUsage("Antigravity 1.1.10"))
}
