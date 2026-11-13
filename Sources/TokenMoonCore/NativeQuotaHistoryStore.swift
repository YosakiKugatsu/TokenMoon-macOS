// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Publishes only native, account-attributed readings. Legacy forecast seeds
/// remain local and never masquerade as newly observed provider data.
public actor NativeQuotaHistoryStore {
    private let file: URL
    private var observations: [QuotaWireObservation] = []
    private var loaded = false
    private static let retention: TimeInterval = 365 * 86400
    private static let flatInterval: TimeInterval = 30 * 60

    public init(directory: URL) { file = directory.appending(path: "native-quota-observations-v1.json") }

    public func load() -> [QuotaWireObservation] {
        loadIfNeeded()
        return observations
    }

    public func record(_ accounts: [QuotaAccount], now: Date = .now) -> [QuotaWireObservation] {
        loadIfNeeded()
        let cutoff = now.addingTimeInterval(-Self.retention)
        let prior = observations
        observations = observations.filter { $0.isValid && $0.observedAt >= cutoff && $0.observedAt <= now }
        let native = Self.liveSamples(accounts).filter { $0.observedAt >= cutoff && $0.observedAt <= now }
        var latest: [QuotaSeriesKey: QuotaWireObservation] = [:]
        for row in observations where latest[row.seriesKey].map({ $0.observedAt < row.observedAt }) ?? true {
            latest[row.seriesKey] = row
        }
        for row in native.sorted(by: Self.order) {
            if let last = latest[row.seriesKey] {
                guard row.observedAt > last.observedAt else { continue }
                let unchanged = row.usedPercent == last.usedPercent && row.durationSeconds == last.durationSeconds
                    && row.plan == last.plan && row.windowLabel == last.windowLabel
                    && Self.sameReset(row.resetsAt, last.resetsAt)
                guard !unchanged || row.observedAt.timeIntervalSince(last.observedAt) >= Self.flatInterval else { continue }
            }
            observations.append(row)
            latest[row.seriesKey] = row
        }
        observations.sort(by: Self.order)
        if observations != prior { needsSave = true }
        if loaded, needsSave {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(observations).write(to: file, options: .atomic)
                needsSave = false
            } catch {
                // In-memory samples remain available; retry the write on a later poll.
            }
        }
        return observations
    }

    /// The latest live measurements, before archive cadence drops repeated flat
    /// readings. Used for current calculations without changing the sync cadence.
    public static func liveSamples(_ accounts: [QuotaAccount]) -> [QuotaWireObservation] {
        accounts.filter { $0.id != "antigravity:ambient-cli" }.flatMap { account in
            account.windows.compactMap { window in
                guard let observed = QuotaObservation(account: account, window: window) else { return nil }
                return sample(observed, account: account, window: window)
            }
        }
    }

    /// Call only after the native client confirms the active account and workspace.
    /// An archived percentage can fill the display, but cannot become a new observation.
    public static func lastKnownCodexAccount(
        _ account: QuotaAccount, from archive: [QuotaWireObservation], previous: QuotaAccount? = nil,
        now: Date = .now
    ) -> QuotaAccount? {
        guard account.agent == .codex, account.windows.isEmpty,
              let email = creatorAccountEmail(account.accountEmail) else { return nil }
        let prefix = account.id + "/"
        struct Reading {
            let window: QuotaWindow
            let time: Date
            let plan: String?
        }
        var latestByWindow: [String: Reading] = [:]
        func add(_ window: QuotaWindow, time: Date, plan: String?) {
            guard window.isValid, time.timeIntervalSinceReferenceDate.isFinite, time <= now,
                  latestByWindow[window.id].map({ $0.time <= time }) ?? true else { return }
            latestByWindow[window.id] = Reading(window: window, time: time, plan: plan)
        }
        for row in archive where row.agent == .codex && row.windowID.hasPrefix(prefix)
            && row.account.caseInsensitiveCompare(email) == .orderedSame && row.isValid {
            let window = QuotaWindow(id: String(row.windowID.dropFirst(prefix.count)), label: row.windowLabel,
                                     usedPercent: row.usedPercent, resetsAt: row.resetsAt, durationSeconds: row.durationSeconds)
            add(window, time: row.observedAt, plan: row.plan)
        }
        // Use the last live in-memory response for readings not persisted by the
        // flat archive cadence. Never give a recovered value a newer timestamp.
        if let previous, previous.agent == .codex, previous.id == account.id, !previous.isCachedReading,
           previous.accountEmail?.caseInsensitiveCompare(email) == .orderedSame {
            for window in previous.windows {
                guard let time = previous.observationTime(for: window) else { continue }
                add(window, time: time, plan: previous.plan)
            }
        }
        let latest = latestByWindow.values.sorted {
            $0.time == $1.time ? $0.window.id < $1.window.id : $0.time > $1.time
        }
        let plan = account.plan ?? latest.first(where: { $0.plan != nil })?.plan
        let current = latest.filter { reading in
            // Select the last observation before checking the cycle. If the
            // provider changed a reset, an older superseded date must not reappear.
            guard let reset = reading.window.resetsAt, reset.timeIntervalSinceReferenceDate.isFinite, reset > now,
                  let duration = reading.window.durationSeconds, duration.isFinite, duration > 0,
                  reading.time >= reset.addingTimeInterval(-duration) else { return false }
            return plan.map { reading.plan?.caseInsensitiveCompare($0) == .orderedSame } ?? true
        }
        guard let newest = current.first else { return nil }
        let windows = current.map { reading in
            let window = reading.window
            return QuotaWindow(id: window.id, label: window.label, usedPercent: window.usedPercent,
                               resetsAt: window.resetsAt, durationSeconds: window.durationSeconds, observedAt: reading.time)
        }.sorted {
            let lhsStandard = $0.id.hasPrefix("codex:"), rhsStandard = $1.id.hasPrefix("codex:")
            if lhsStandard != rhsStandard { return lhsStandard }
            return $0.id < $1.id
        }
        return QuotaAccount(id: account.id, agent: .codex, displayName: account.displayName,
                            plan: plan, windows: windows, observedAt: newest.time,
                            note: account.note, accountEmail: email, provenance: .lastKnown)
    }

    /// A local-only fallback for already retained forecast observations.
    /// Require the exact opaque account/window of a fresh native reading.
    public static func localForecastSamples(_ history: [QuotaObservation], accounts: [QuotaAccount]) -> [QuotaWireObservation] {
        var result: [QuotaWireObservation] = []
        let historyByAccount = Dictionary(grouping: history, by: \.accountID)
        for account in accounts where account.liveObservationAt != nil {
            guard let readings = historyByAccount[account.id] else { continue }
            for window in account.windows {
                result += readings.filter { $0.windowID == window.id }.compactMap { sample($0, account: account, window: window) }
            }
        }
        return result
    }

    private var needsSave = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
            let disk = try JSONDecoder().decode([QuotaWireObservation].self, from: Data(contentsOf: file))
            var samples: [QuotaSampleKey: QuotaWireObservation] = [:]
            for point in disk + observations where point.isValid { samples[point.sampleKey] = point }
            observations = samples.values.sorted(by: Self.order)
            loaded = true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            loaded = true
        } catch {
            // Preserve an unreadable archive; live observations can still be used this run.
        }
    }

    private static func sample(_ observed: QuotaObservation, account: QuotaAccount, window: QuotaWindow) -> QuotaWireObservation? {
        guard let email = creatorAccountEmail(account.accountEmail),
              observed.resetsAt.map({ $0 > observed.observedAt }) ?? true else { return nil }
        // The opaque quota account ID disambiguates multiple workspaces with
        // the same sign-in email; it is stable across devices for this account.
        let series = account.id + "/" + window.id
        let millis = (observed.observedAt.timeIntervalSince1970 * 1_000).rounded(.down)
        let observationTime = Date(timeIntervalSince1970: millis / 1_000)
        let sample = QuotaWireObservation(agent: account.agent, account: email, windowID: series, windowLabel: window.label,
                                          observedAt: observationTime, usedPercent: observed.usedPercent,
                                          resetsAt: observed.resetsAt, durationSeconds: window.durationSeconds, plan: account.plan)
        return sample.isValid ? sample : nil
    }

    private static func order(_ lhs: QuotaWireObservation, _ rhs: QuotaWireObservation) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        return (lhs.agent.rawValue, lhs.account.lowercased(), lhs.windowID) < (rhs.agent.rawValue, rhs.account.lowercased(), rhs.windowID)
    }

    static func sameReset(_ lhs: Date?, _ rhs: Date?, tolerance: TimeInterval = 2) -> Bool {
        if let lhs, let rhs { return abs(lhs.timeIntervalSince(rhs)) <= tolerance }
        return lhs == nil && rhs == nil
    }
}

struct QuotaSeriesKey: Hashable, Sendable {
    let agent: Agent
    let account: String
    let window: String

    var id: String { collectorID(agent.rawValue, account, window) }
}

struct QuotaSampleKey: Hashable {
    let series: QuotaSeriesKey
    let milliseconds: Double
}

extension QuotaWireObservation {
    var seriesKey: QuotaSeriesKey { .init(agent: agent, account: account.lowercased(), window: windowID) }
    var sampleKey: QuotaSampleKey {
        .init(series: seriesKey, milliseconds: (observedAt.timeIntervalSince1970 * 1_000).rounded())
    }
}
