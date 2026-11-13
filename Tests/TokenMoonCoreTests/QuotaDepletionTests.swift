// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct QuotaDepletionTests {
    private let epoch = Date(timeIntervalSince1970: 1_762_000_000)

    private func day(_ offset: Double) -> Date { epoch.addingTimeInterval(offset * 86_400) }

    private func weekly(_ day: Double, _ used: Double, reset: Double?, account: String = "main@example.com",
                        seconds: TimeInterval = QuotaDepletion.weeklySeconds) -> QuotaWireObservation {
        QuotaWireObservation(agent: .codex, account: account, windowID: "weekly-main", windowLabel: "7 天",
                             observedAt: self.day(day), usedPercent: used,
                             resetsAt: reset.map(self.day), durationSeconds: seconds)
    }

    @Test func addsWeeklyUseAcrossResetsWithoutInventingPreResetTail() throws {
        let one = weekly(10, 30, reset: 14)
        let two = weekly(13, 80, reset: 14)
        let points = [
            one, two, two, // independent devices can carry the same reading
            weekly(15, 35, reset: 21), weekly(20, 95, reset: 21),
            weekly(22, 15, reset: 28),
            weekly(16, 70, reset: 21, account: "second@example.com"),
            weekly(13, 99, reset: 13.1, account: "short@example.com", seconds: 18_000),
        ]
        let options = QuotaDepletion.options(observations: points, bounds: day(9)..<day(24), historyStart: day(9))
        let first = try #require(options.first)
        #expect(options.count == 2)
        #expect(first.title.contains("m***in@example.com"))
        #expect(!first.title.contains("main@example.com"))
        // 50 before the first reset, 95 in the next cycle, 15 in the
        // current cycle. The missing first cycle's 80%→reset tail is unknown.
        #expect(first.consumedPercent == 160)
        #expect(first.observedIntervals == 4 && first.cycles == 3)
        #expect(options.last?.consumedPercent == 70)
    }

    @Test func correctionCreatesBarrierAndShiftedPredictionDoesNotCreateReset() throws {
        let before = weekly(10, 10, reset: 14)
        let first = weekly(11, 60, reset: 14)
        let fixed = QuotaDepletion.options(
            observations: [before, first, weekly(12, 85, reset: 14), weekly(13, 70, reset: 14),
                           weekly(13.25, 85, reset: 14), weekly(15, 20, reset: 21)],
            bounds: day(10.5)..<day(14), historyStart: day(9)
        )
        #expect(fixed.first?.consumedPercent == 15)
        #expect(fixed.first?.partialHistory == true)
        let moving = QuotaDepletion.options(
            observations: [weekly(10, 30, reset: 16), weekly(10.25, 40, reset: 16.25)],
            bounds: day(10)..<day(11), historyStart: day(9)
        )
        #expect(moving.first?.consumedPercent == 10)
        #expect(moving.first?.cycles == 1)
    }

    @Test func matchesCPARecentUsageFixtureAndDoesNotCapSelectedRange() throws {
        let iso = ISO8601DateFormatter()
        func at(_ value: String) -> Date { iso.date(from: value)! }
        func point(_ time: String, _ used: Double, reset: String) -> QuotaWireObservation {
            QuotaWireObservation(agent: .codex, account: "fixture@example.com", windowID: "codex-week",
                                 windowLabel: "7 days", observedAt: at(time), usedPercent: used,
                                 resetsAt: at(reset), durationSeconds: QuotaDepletion.weeklySeconds)
        }
        let start = at("2026-10-01T00:00:00Z")
        let oldReset = "2026-10-08T00:00:00Z"
        let newReset = "2026-10-09T00:00:00Z"
        let samples = [
            point("2026-10-01T01:00:00Z", 30, reset: oldReset),
            point("2026-10-01T01:30:00Z", 30, reset: oldReset),
            point("2026-10-01T02:00:00Z", 40, reset: oldReset),
            point("2026-10-01T03:00:00Z", 40, reset: oldReset),
            point("2026-10-02T01:00:00Z", 70, reset: newReset),
            point("2026-10-02T02:00:00Z", 70, reset: newReset),
        ]
        // CPA internal/analytics/recent_usage_test.go selects these exact
        // boundaries after prorating the oldest 30% interval to 20%.
        let parity = try #require(QuotaDepletion.options(
            observations: samples,
            bounds: at("2026-10-01T00:20:00Z")..<at("2026-10-02T01:00:00Z"), historyStart: start
        ).first)
        #expect(parity.consumedPercent == 100)
        #expect(parity.observedIntervals == 3 && parity.cycles == 2 && !parity.partialHistory)

        let whole = try #require(QuotaDepletion.options(
            observations: samples, bounds: start..<at("2026-10-02T03:00:00Z"), historyStart: start
        ).first)
        #expect(whole.consumedPercent == 110)
        #expect(whole.observedIntervals == 3 && whole.cycles == 2)

        // No use after the latest confirmation, even when the provider has
        // subsequently returned a flat percentage.
        #expect(QuotaDepletion.options(
            observations: samples,
            bounds: at("2026-10-02T01:01:00Z")..<at("2026-10-02T03:00:00Z"), historyStart: start
        ).isEmpty)

        let historical = try #require(QuotaDepletion.options(
            observations: samples, bounds: start..<at("2026-10-02T00:45:00Z"), historyStart: start
        ).first)
        #expect(historical.consumedPercent == 40)

        let incomplete = try #require(QuotaDepletion.options(
            observations: samples, bounds: start..<at("2026-10-02T03:00:00Z"),
            historyStart: at("2026-10-01T00:30:00Z")
        ).first)
        #expect(incomplete.consumedPercent == 80 && incomplete.partialHistory)
    }

    @Test func unusedFutureResetIsNotABarrierButMissingEvidenceIs() throws {
        let observations = [
            weekly(10, 30, reset: 14), weekly(11, 40, reset: 14),
            // Its reported window starts at day 13, after the day 12 reading.
            weekly(12, 0, reset: 20),
        ]
        let bounds = day(7)..<day(13)
        let value = try #require(QuotaDepletion.options(observations: observations, bounds: bounds).first)
        #expect(value.consumedPercent == 40 && !value.partialHistory)
        #expect(QuotaDepletion.options(
            observations: observations + [weekly(12.25, 50, reset: nil)], bounds: bounds
        ).isEmpty)
        let missingDuration = QuotaWireObservation(agent: .codex, account: "main@example.com",
                                                   windowID: "weekly-main", windowLabel: "7 天",
                                                   observedAt: day(12.25), usedPercent: 50, resetsAt: day(14))
        #expect(QuotaDepletion.options(observations: observations + [missingDuration], bounds: bounds).isEmpty)
    }

    @Test func nativeArchivePersistsVerifiedSamplesAndExcludesForecastOnlyReadings() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NativeQuotaHistoryStore(directory: dir)
        let window = QuotaWindow(id: "weekly", label: "7 天", usedPercent: 34, resetsAt: day(7), durationSeconds: 604_800)
        func account(_ offset: Double, email: String? = "test@example.com", provenance: QuotaReadingProvenance = .live) -> QuotaAccount {
            QuotaAccount(id: "official-id", agent: .codex, displayName: "Test", windows: [window],
                         observedAt: day(offset), accountEmail: email, provenance: provenance)
        }
        let seed = QuotaObservation(accountID: "official-id", windowID: "weekly", observedAt: day(0.5), usedPercent: 5, resetsAt: day(7))
        let localOnly = NativeQuotaHistoryStore.localForecastSamples([seed], accounts: [account(1)])
        #expect(localOnly.count == 1)
        let initial = await store.record([account(1), account(0.6, email: nil), account(0.8, provenance: .cached)], now: day(1))
        let next = await store.record([account(1.01)], now: day(1.01))
        let later = await store.record([account(1.04)], now: day(1.04))
        #expect(initial.count == 1 && next == initial && later.count == 2)
        // The subscriptions page can price through the latest measured flat
        // reading without adding it to the shared archive or trusting a cache.
        let current = NativeQuotaHistoryStore.liveSamples([
            account(1.01), account(1.02, provenance: .cached), account(1.03, email: nil)
        ])
        #expect(current.count == 1 && current.first?.windowID == initial.first?.windowID)
        #expect(current.first?.observedAt == day(1.01))
        let reread = await NativeQuotaHistoryStore(directory: dir).load()
        #expect(reread == later)
        #expect(reread.allSatisfy { $0.observedAt != seed.observedAt })
    }
}
