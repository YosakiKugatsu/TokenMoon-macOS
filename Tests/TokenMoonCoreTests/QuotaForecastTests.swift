// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Suite("Quota forecasts from observed subscription windows")
struct QuotaForecastTests {
    private let now = Date(timeIntervalSince1970: 1_794_320_000)
    private let accountID = "codex-account-a"
    private let windowID = "five-hour"

    private func reading(
        _ minutesAgo: Double, _ used: Double, reset: Date?,
        accountID: String? = nil, windowID: String? = nil
    ) -> QuotaObservation {
        QuotaObservation(accountID: accountID ?? self.accountID, windowID: windowID ?? self.windowID,
                         observedAt: now.addingTimeInterval(-minutesAgo * 60), usedPercent: used, resetsAt: reset)
    }

    private func account(_ used: Double, _ reset: Date?, minutesAgo: Double = 0) -> QuotaAccount {
        QuotaAccount(id: accountID, agent: .codex, displayName: "Test",
                     windows: [QuotaWindow(id: windowID, label: "5 hours", usedPercent: used,
                                           resetsAt: reset, durationSeconds: 5 * 3_600)],
                     observedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func predictsBeforeResetWithoutMixingAccountsOrWindows() throws {
        let reset = now.addingTimeInterval(3 * 3_600)
        let current = account(60, reset)
        let history = [reading(120, 20, reset: reset), reading(60, 40, reset: reset),
                       reading(30, 92, reset: reset, accountID: "codex-account-b"),
                       reading(10, 91, reset: reset, windowID: "weekly"),
                       reading(0, 99, reset: reset)]
        let prediction = try #require(QuotaForecast.estimate(account: current, window: current.windows[0],
                                                              observations: history, now: now))
        let exhaustion = try #require(prediction.exhaustsAt)
        #expect(abs(exhaustion.timeIntervalSince(now) - 2 * 3_600) < 1)
        #expect(!prediction.lastsUntilReset)
        #expect(prediction.sampleCount == 3)
        #expect(abs(prediction.percentagePointsPerHour - 20) < 0.000_01)
    }

    @Test func projectsPastResetWithoutShowingACrossCycleDate() throws {
        let reset = now.addingTimeInterval(3_600)
        let current = account(30, reset)
        let history = [reading(120, 10, reset: reset), reading(60, 20, reset: reset)]
        let prediction = try #require(QuotaForecast.estimate(account: current, window: current.windows[0],
                                                              observations: history, now: now))
        #expect(prediction.lastsUntilReset)
        #expect(prediction.exhaustsAt == nil)
        #expect(prediction.percentagePointsPerHour == 10)
    }

    @Test func refillAndResetJumpDiscardEarlierPace() {
        let reset = now.addingTimeInterval(60 * 60)
        let refill = account(10, reset)
        let prior = [reading(180, 20, reset: reset), reading(120, 50, reset: reset),
                     reading(60, 70, reset: reset), reading(35, 5, reset: reset), reading(15, 7, reset: reset)]
        #expect(QuotaForecast.estimate(account: refill, window: refill.windows[0], observations: prior, now: now) == nil)

        // An early reset can move the deadline even when the next used percentage is larger.
        let moved = now.addingTimeInterval(2 * 3_600)
        let current = account(25, moved)
        let olderWindow = [reading(180, 10, reset: reset), reading(120, 15, reset: reset),
                           reading(60, 20, reset: reset), reading(15, 24, reset: moved)]
        #expect(QuotaForecast.estimate(account: current, window: current.windows[0],
                                      observations: olderWindow, now: now) == nil)
    }

    @Test func rejectsDuplicateShortOrStaleEvidence() {
        let reset = now.addingTimeInterval(3_600)
        let current = account(20, reset)
        let snapshots = [reading(20, 10, reset: reset), reading(20, 10, reset: reset),
                         reading(10, 15, reset: reset)]
        #expect(QuotaForecast.estimate(account: current, window: current.windows[0],
                                      observations: snapshots, now: now) == nil)
        let stale = account(30, reset, minutesAgo: 30)
        let older = [reading(150, 10, reset: reset), reading(90, 20, reset: reset)]
        #expect(QuotaForecast.estimate(account: stale, window: stale.windows[0], observations: older, now: now) == nil)
    }

    @Test func repeatedPollsPreserveOnlyBothEndsOfAFlatRun() {
        let reset = now.addingTimeInterval(3_600)
        var stored: [QuotaObservation] = []
        for minutesAgo: Double in [90, 60, 30, 0, 0] {
            stored = QuotaForecast.recording(accounts: [account(20, reset, minutesAgo: minutesAgo)],
                                            into: stored, now: now)
        }
        #expect(stored.map(\.observedAt) == [now.addingTimeInterval(-90 * 60), now])
    }

    @Test func cachedAndLastKnownBalancesAreNotNewObservations() {
        let reset = now.addingTimeInterval(3_600)
        let current = account(30, reset)
        let history = [reading(120, 10, reset: reset), reading(60, 20, reset: reset)]
        let cached = QuotaAccount(id: current.id, agent: current.agent, displayName: current.displayName,
                                  windows: current.windows, provenance: .cached)
        let stale = current.lastKnown
        #expect(cached.observedAt == nil)
        #expect(cached.isCachedReading && cached.freshness(now: now) == .cached)
        #expect(stale.observedAt == current.observedAt)
        #expect(stale.freshness(now: now) == .stale)
        #expect(current.freshness(for: current.windows[0], now: reset) == .resetPending)
        #expect(QuotaForecast.recording(accounts: [cached, stale], into: history, now: now) == history)
        for unusable in [cached, stale] {
            #expect(QuotaForecast.estimate(account: unusable, window: unusable.windows[0],
                                           observations: history, now: now) == nil)
        }
    }

    @Test func unreadableHistoryIsPreservedAndRecoversWithoutLosingLiveReadings() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "quota-observations.json")
        let store = QuotaHistoryStore(directory: directory)
        let reset = now.addingTimeInterval(3_600)
        _ = await store.record([account(10, reset, minutesAgo: 120)], now: now)
        let valid = try Data(contentsOf: file)
        let damaged = Data(#"{"interrupted":"#.utf8)
        try damaged.write(to: file, options: .atomic)

        let transient = await store.record([account(20, reset, minutesAgo: 60)], now: now)
        let issue = await store.persistenceIssue
        #expect(issue == .unreadableHistory)
        #expect(try Data(contentsOf: file) == damaged)
        #expect(transient.map(\.usedPercent) == [10, 20])

        try valid.write(to: file, options: .atomic)
        let restored = await store.record([account(30, reset)], now: now)
        let recoveredIssue = await store.persistenceIssue
        #expect(recoveredIssue == nil)
        #expect(restored.map(\.usedPercent) == [10, 20, 30])
        #expect(try JSONDecoder().decode([QuotaObservation].self, from: Data(contentsOf: file)) == restored)
    }

    @Test func magpieSeedRequiresVerifiedIdentityAndOneExactDeadline() throws {
        let reset = now.addingTimeInterval(3_600)
        let current = account(20, reset)
        let verified = QuotaAccount(id: current.id, agent: current.agent, displayName: "Test",
                                    windows: current.windows, observedAt: now, accountEmail: "A@example.com")
        let displayedOnly = QuotaAccount(id: current.id, agent: current.agent, displayName: "A@example.com",
                                         windows: current.windows, observedAt: now)
        let dates = ISO8601DateFormatter()
        let points = [120.0, 60].map { minutes in
            ["at": dates.string(from: now.addingTimeInterval(-minutes * 60)), "left": 90,
             "resetsAt": dates.string(from: reset)] as [String: Any]
        }
        let oldReset = now.addingTimeInterval(3_599)
        let wrongDeadline = points.map { point in point.merging(["resetsAt": dates.string(from: oldReset)]) { _, new in new } }
        let unique = try JSONSerialization.data(withJSONObject: ["codex|a@example.com": [
            "5 hours": points, "other window": wrongDeadline
        ]])
        let seed = QuotaForecast.seedFromMagpie(data: unique, accounts: [verified])
        #expect(seed.count == 2)
        #expect(seed.allSatisfy { $0.accountID == current.id && $0.windowID == windowID && $0.usedPercent == 10 })
        #expect(QuotaForecast.seedFromMagpie(data: unique, accounts: [displayedOnly]).isEmpty)
        let ambiguous = try JSONSerialization.data(withJSONObject: ["codex|a@example.com": [
            "5 hours": points, "other window": points
        ]])
        #expect(QuotaForecast.seedFromMagpie(data: ambiguous, accounts: [verified]).isEmpty)
    }
}
