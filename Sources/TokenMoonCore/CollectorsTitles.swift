// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Display metadata from an explicit name record. This type is intentionally
/// not Codable and never belongs to a UsageRequest or a persisted ledger.
struct SessionTitleEvidence {
    let title: String
    let priority: Int
    let updatedAt: Date?

    func fallbackDate(_ date: Date) -> Self {
        .init(title: title, priority: priority, updatedAt: updatedAt ?? date)
    }

    func isPreferred(to old: Self) -> Bool {
        guard priority == old.priority else { return priority > old.priority }
        if let updatedAt, let previous = old.updatedAt { return updatedAt >= previous }
        // Native append order is authoritative when metadata is not timestamped.
        return true
    }
}

func collectorSessionTitleKey(device: String, agent: Agent, session: String) -> String {
    // Match UsageRequest.sessionKey, including the normalized device UUID.
    [device.lowercased(), agent.rawValue, session].joined(separator: "/")
}

func explicitSessionTitle(_ raw: Any?) -> String? {
    guard let string = raw as? String else { return nil }
    let oneLine = string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !oneLine.isEmpty, oneLine.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
    return String(oneLine.prefix(512))
}

func putSessionTitle(_ title: SessionTitleEvidence, for key: String, in titles: inout [String: SessionTitleEvidence]) {
    if let old = titles[key], !title.isPreferred(to: old) { return }
    titles[key] = title
}

/// Find the explicit title index for standard Codex homes and configured
/// transcript roots/files, without consulting prompt text or SQLite previews.
func codexTitleIndexes(roots: [URL]) -> [URL] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    var paths: Set<URL> = []
    for root in roots where root.isFileURL {
        let url = root.standardizedFileURL
        let homeCandidate: URL
        if url.lastPathComponent == "session_index.jsonl" {
            homeCandidate = url.deletingLastPathComponent()
        } else {
            let regular = (try? url.resourceValues(forKeys: keys).isRegularFile) == true
            let directory = regular ? url.deletingLastPathComponent() : url
            var cursor = directory
            while cursor.path != "/" && !["sessions", "archived_sessions"].contains(cursor.lastPathComponent) {
                cursor.deleteLastPathComponent()
            }
            homeCandidate = cursor.path == "/" ? directory : cursor.deletingLastPathComponent()
        }
        let index = homeCandidate.appendingPathComponent("session_index.jsonl")
        guard let values = try? index.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        paths.insert(index)
    }
    return paths.sorted { $0.path < $1.path }
}

func collectCodexTitles(_ index: URL, device: String) throws -> [String: SessionTitleEvidence] {
    let dates = CollectorDates()
    var titles: [String: SessionTitleEvidence] = [:]
    try readCollectorLines(index, markers: ["\"thread_name\""]) { row in
        guard let session = row.text("id"), let name = explicitSessionTitle(row["thread_name"]) else { return }
        let key = collectorSessionTitleKey(device: device, agent: .codex, session: session)
        let evidence = SessionTitleEvidence(title: name, priority: 1, updatedAt: dates.parse(row.text("updated_at")))
        putSessionTitle(evidence, for: key, in: &titles)
    }
    return titles
}
