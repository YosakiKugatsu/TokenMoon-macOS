// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public actor QuotaHistoryStore {
    public enum PersistenceIssue: Equatable, Sendable {
        case unreadableHistory
        case cannotSaveHistory

        public var description: String {
            switch self {
            case .unreadableHistory: "无法读取额度历史，原文件已保留"
            case .cannotSaveHistory: "本次额度历史未能保存"
            }
        }
    }

    private struct SampleKey: Hashable {
        let account: String
        let window: String
        let date: Date
        init(_ point: QuotaObservation) {
            account = point.accountID
            window = point.windowID
            date = point.observedAt
        }
    }

    private struct SeedKey: Hashable {
        let account: String
        let window: String
        let reset: Date
    }

    private struct Stamp: Equatable, Sendable {
        let number: UInt64
        let size: UInt64
        let modified: Date

        /// nil means absent, not inaccessible or malformed.
        static func read(_ file: URL) throws -> Self? {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return nil
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let number = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            return Self(number: number.uint64Value, size: size.uint64Value, modified: modified)
        }
    }

    private let directory: URL
    private var observations: [QuotaObservation] = []
    private var diskSnapshot: (stamp: Stamp, samples: [QuotaObservation])?
    private var seededWindows: Set<SeedKey> = []
    public private(set) var persistenceIssue: PersistenceIssue?

    public init(directory: URL) { self.directory = directory }

    public func record(_ accounts: [QuotaAccount], now: Date = .now) -> [QuotaObservation] {
        let file = directory.appending(path: "quota-observations.json")
        // Recheck the on-disk snapshot before replacing it. An interrupted
        // import, incompatible file or temporarily unreadable volume must
        // never become an apparently valid empty history on the next poll.
        let disk: [QuotaObservation]?
        let stamp: Stamp?
        do {
            let checked = try Stamp.read(file)
            if let checked {
                if let diskSnapshot, diskSnapshot.stamp == checked {
                    disk = diskSnapshot.samples
                } else {
                    let parsed = try JSONDecoder().decode([QuotaObservation].self, from: Data(contentsOf: file))
                    guard try Stamp.read(file) == checked else { throw CocoaError(.fileReadUnknown) }
                    diskSnapshot = (checked, parsed)
                    disk = parsed
                }
            } else {
                diskSnapshot = nil
                disk = []
            }
            stamp = checked
            persistenceIssue = nil
        } catch {
            disk = nil
            stamp = nil
            diskSnapshot = nil
            persistenceIssue = .unreadableHistory
        }
        let previous: [QuotaObservation]
        if let disk, disk != observations {
            var merged: [SampleKey: QuotaObservation] = [:]
            for sample in observations { merged[SampleKey(sample)] = sample }
            for sample in disk { merged[SampleKey(sample)] = sample }
            previous = Array(merged.values)
        } else {
            previous = observations
        }
        let liveAccounts = accounts.filter { $0.liveObservationAt != nil }
        let newCycles = liveAccounts.filter { account in
            guard account.accountEmail != nil else { return false }
            let keys = account.windows.compactMap { window in
                window.resetsAt.map { SeedKey(account: account.id, window: window.id, reset: $0) }
            }
            let needsSeed = keys.contains { !seededWindows.contains($0) }
            seededWindows.formUnion(keys)
            return needsSeed
        }
        let seed: [QuotaObservation]
        if newCycles.isEmpty {
            seed = []
        } else {
            let knownSamples = Set(previous.map(SampleKey.init))
            seed = QuotaForecast.seedFromLocalMagpie(accounts: newCycles)
                .filter { !knownSamples.contains(SampleKey($0)) }
        }
        let updated = QuotaForecast.recording(accounts: liveAccounts, into: previous + seed, now: now)
        observations = updated
        if let disk, !liveAccounts.isEmpty, updated != disk {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(updated)
                guard try Stamp.read(file) == stamp else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: file, options: .atomic)
                if let saved = try? Stamp.read(file) {
                    diskSnapshot = (saved, updated)
                } else {
                    diskSnapshot = nil
                }
            } catch {
                persistenceIssue = .cannotSaveHistory
            }
        }
        return updated
    }
}
