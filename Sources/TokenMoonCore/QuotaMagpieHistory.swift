// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension QuotaForecast {
    /// An optional read-only seed from the local Magpie file. It is never used
    /// to discover accounts or to replace a live provider's remaining balance.
    public static func seedFromLocalMagpie(accounts: [QuotaAccount]) -> [QuotaObservation] {
        guard accounts.contains(where: { $0.accountEmail != nil && $0.liveObservationAt != nil }) else { return [] }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/magpie/quota-history.json")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let info = try? file.resourceValues(forKeys: keys), info.isRegularFile == true,
              info.isSymbolicLink != true, let size = info.fileSize, size <= 16 * 1_024 * 1_024,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        return seedFromMagpie(data: data, accounts: accounts)
    }

    /// Magpie groups the file by provider and lowercased account email.
    /// Same-deadline lines that could describe multiple buckets are skipped.
    static func seedFromMagpie(data: Data, accounts: [QuotaAccount]) -> [QuotaObservation] {
        struct Point: Decodable {
            let at: String
            let left: Double
            let resetsAt: String?
        }
        guard let history = try? JSONDecoder().decode([String: [String: [Point]]].self, from: data) else { return [] }
        let iso = ISO8601DateFormatter()
        let preciseISO = ISO8601DateFormatter()
        preciseISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ string: String) -> Date? { iso.date(from: string) ?? preciseISO.date(from: string) }

        func key(for account: QuotaAccount) -> String? {
            let provider: String
            switch account.agent {
            case .codex: provider = "codex"
            case .claudeCode: provider = "claude"
            default: return nil
            }
            guard let email = account.accountEmail?.lowercased(),
                  email.split(separator: "@", omittingEmptySubsequences: false).count == 2,
                  !email.hasPrefix("@"), !email.hasSuffix("@"),
                  !email.contains(where: { $0.isWhitespace || $0 == "|" }) else { return nil }
            return provider + "|" + email
        }
        let identified = Dictionary(grouping: accounts.compactMap { account in key(for: account).map { ($0, account) } },
                                    by: { $0.0 })
        var observations: [QuotaObservation] = []
        for (identity, candidates) in identified {
            guard candidates.count == 1, let account = candidates.first?.1,
                  let observedAt = account.liveObservationAt, let lines = history[identity] else { continue }
            let liveDeadlines = Dictionary(grouping: account.windows.compactMap { window in
                window.resetsAt.map { ($0, window) }
            }, by: { $0.0 })
            for (reset, sameDeadline) in liveDeadlines {
                guard reset > observedAt, sameDeadline.count == 1, let window = sameDeadline.first?.1 else { continue }
                var cutoff = observedAt.addingTimeInterval(-7 * 24 * 3_600)
                if let span = window.durationSeconds, span.isFinite, span > 0 {
                    cutoff = max(cutoff, reset.addingTimeInterval(-span))
                }
                let matches: [[QuotaObservation]] = lines.values.compactMap { points in
                    var dated: [Date: QuotaObservation] = [:]
                    for point in points {
                        guard point.left.isFinite, (0...100).contains(point.left),
                              let deadline = point.resetsAt.flatMap(date), deadline == reset,
                              let at = date(point.at), at >= cutoff, at < observedAt else { continue }
                        dated[at] = QuotaObservation(accountID: account.id, windowID: window.id,
                                                     observedAt: at, usedPercent: 100 - point.left, resetsAt: reset)
                    }
                    return dated.isEmpty ? nil : Array(dated.values)
                }
                guard matches.count == 1, let seed = matches.first, seed.count >= minimumSamples - 1 else { continue }
                observations.append(contentsOf: seed)
            }
        }
        return observations.sorted { $0.observedAt < $1.observedAt }
    }
}
