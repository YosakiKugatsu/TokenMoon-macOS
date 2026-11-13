// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import CryptoKit
import Foundation
import Darwin

public struct CollectionReport: Sendable {
    public var agent: Agent
    public var files: Int
    public var requests: Int
    public var note: String
}

public struct CollectionResult: Sendable {
    public var requests: [UsageRequest]
    public var reports: [CollectionReport]
    /// Per-device provisional Claude request IDs with a unique, observed successor.
    /// Only stable digests of request identifiers are returned, never log content.
    public var supersededRequestIDs: Set<String>
    /// Explicit names for the local UI, keyed by UsageRequest.sessionKey.
    /// Kept separate from usage records so they never enter export or sync.
    public var sessionTitles: [String: String]
}

/// Scans existing local logs read-only. Hold one instance across refreshes to
/// reuse the in-memory cache for unchanged files. Only normalized usage and
/// explicit local display names are cached.
public struct UsageCollectors: Sendable {
    private let cache = CollectorCache()

    public init() {}

    public static func defaultRoots() -> [Agent: [URL]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        func configured(_ key: String, fallback: URL) -> URL {
            if let value = env[key], value.hasPrefix("/") { return URL(fileURLWithPath: value) }
            return fallback
        }
        let codex = configured("CODEX_HOME", fallback: home.appendingPathComponent(".codex"))
        let claude = configured("CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude"))
        let gemini = configured("GEMINI_CLI_HOME", fallback: home).appendingPathComponent(".gemini")
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            .codex: ["sessions", "archived_sessions"].map { codex.appendingPathComponent($0) },
            .claudeCode: [claude.appendingPathComponent("projects"), support.appendingPathComponent("TokenMoon Community/Telemetry")],
            .claudeDesktop: ["Claude", "Claude-3p"].flatMap { name in
                ["local-agent-mode-sessions", "claude-code-sessions"].map { support.appendingPathComponent("\(name)/\($0)") }
            },
            .antigravity: ["antigravity/conversations", "antigravity-insiders/conversations", "antigravity-cli/brain", "antigravity-cli/conversations"].map { gemini.appendingPathComponent($0) }
        ]
    }

    /// Supplying a key replaces the defaults for that agent. An empty array disables its direct discovery.
    /// An explicit Claude Desktop root may point directly to the projects folder or a transcript.
    public func scan(deviceID: String, roots: [Agent: [URL]] = [:],
                     codexCreatorAccounts: CodexCreatorAccounts = .init()) throws -> CollectionResult {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.deviceID != deviceID {
            cache.deviceID = deviceID
            cache.files.removeAll()
            cache.titleIndexes.removeAll()
            cache.codexAuthDatabases.removeAll()
            cache.result = nil
        }
        let defaults = Self.defaultRoots()
        var candidates: [CollectorKey: URL] = [:]
        var discoveryErrors: [Agent: Int] = [:]
        for agent in Agent.localCollectors {
            for root in roots[agent] ?? defaults[agent] ?? [] where root.isFileURL {
                try Task.checkCancellation()
                let url = root.standardizedFileURL
                for file in discover(url, agent: agent, custom: roots[agent] != nil, errors: &discoveryErrors) {
                    candidates[CollectorKey(agent: agent, path: file.path)] = file
                }
            }
        }
        let oldCache = cache.files
        var nextCache: [CollectorKey: CachedCollection] = [:]
        var nextTitleCache: [URL: CachedTitleIndex] = [:]
        var counts: [Agent: Int] = [:]
        var changed = cache.codexCreatorAccounts != codexCreatorAccounts
        let codexRoots = roots[.codex] ?? defaults[.codex] ?? []
        let indexes = codexTitleIndexes(roots: codexRoots)
        for index in indexes {
            try Task.checkCancellation()
            do {
                let stamp = try fingerprint(index)
                let cached: CachedTitleIndex
                if let old = cache.titleIndexes[index], old.stamp == stamp {
                    cached = old
                } else {
                    cached = CachedTitleIndex(stamp: stamp, titles: try collectCodexTitles(index, device: deviceID))
                    changed = true
                }
                nextTitleCache[index] = cached
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let old = cache.titleIndexes[index] {
                    nextTitleCache[index] = old
                }
            }
        }
        let authByTurn = try collectCodexRequestAuth(roots: codexRoots, cache: cache)
        var authByThread: [String: [CodexAuthTurn: CodexAuthEvidence]] = [:]
        for (turn, mode) in authByTurn {
            authByThread[turn.threadID, default: [:]][turn] = mode
        }
        // Lexical ordering makes duplicates across copied/archived sources deterministic.
        let fileKeys = candidates.keys.sorted { ($0.agent.rawValue, $0.path) < ($1.agent.rawValue, $1.path) }
        for key in fileKeys {
            try Task.checkCancellation()
            guard let file = candidates[key] else { continue }
            counts[key.agent, default: 0] += 1
            do {
                let stamp = try fingerprint(file)
                let entry: CachedCollection
                if let cached = oldCache[key], cached.stamp == stamp,
                   cached.codexAuthByTurn == (cached.codexThreadID.flatMap { authByThread[$0] } ?? [:]) {
                    entry = cached
                } else {
                    let requests: [UsageRequest]
                    var codexThreadID: String?
                    var codexCreator: CodexCreatorIdentity?
                    var localTitles: [String: SessionTitleEvidence] = [:]
                    var aliasClaims: [String: Set<String>] = [:]
                    switch key.agent {
                    case .codex:
                        requests = try collectCodex(file, device: deviceID, authByTurn: authByTurn,
                                                    sourceThreadID: &codexThreadID, sourceCreator: &codexCreator)
                    case .claudeCode, .claudeDesktop:
                        if file.lastPathComponent.hasSuffix(".otlp.jsonl") {
                            requests = try collectClaudeTelemetry(file, device: deviceID, agent: key.agent)
                        } else {
                            requests = try collectClaude(file, device: deviceID, agent: key.agent, titles: &localTitles,
                                                         aliasClaims: &aliasClaims)
                        }
                    case .antigravity: requests = try collectAntigravity(file, device: deviceID)
                    case .cpa: continue
                    }
                    entry = CachedCollection(stamp: stamp, requests: requests, titles: localTitles, aliasClaims: aliasClaims,
                                             codexThreadID: codexThreadID,
                                             codexAuthByTurn: codexThreadID.flatMap { authByThread[$0] } ?? [:],
                                             codexCreator: codexCreator)
                    changed = true
                }
                nextCache[key] = entry
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                discoveryErrors[key.agent, default: 0] += 1
                // A file can be briefly unavailable while its writer rotates it.
                if let cached = oldCache[key] {
                    nextCache[key] = cached
                }
            }
        }
        let reusedFiles = !changed && nextCache.count == cache.files.count && nextTitleCache.count == cache.titleIndexes.count
        if reusedFiles, counts == cache.reportFiles, discoveryErrors == cache.reportErrors, let result = cache.result {
            return result
        }

        var all: [String: UsageRequest] = [:]
        var telemetry: [String: UsageRequest] = [:]
        var aliases: [String: Set<String>] = [:]
        var titles: [String: SessionTitleEvidence] = [:]
        func mergeTitles(_ items: [String: SessionTitleEvidence], modified: Date) {
            for (key, title) in items {
                putSessionTitle(title.fallbackDate(modified), for: key, in: &titles)
            }
        }
        for index in indexes {
            if let entry = nextTitleCache[index] { mergeTitles(entry.titles, modified: entry.stamp.primary.modified) }
        }
        for key in fileKeys {
            try Task.checkCancellation()
            guard let entry = nextCache[key] else { continue }
            let creatorEmail = entry.codexCreator.flatMap { codexCreatorAccounts.email(for: $0) }
            for var row in entry.requests {
                if let creatorEmail, row.sessionCreatorAccountID == entry.codexCreator?.accountID {
                    row.sessionCreatorAccountEmail = creatorEmail
                }
                if row.source == "claude.otel.api_request" || row.source == "claude.otel.api_error" {
                    if let old = telemetry[row.id], old.isFailure, row.isFailure {
                        telemetry[row.id] = enrichClaudeFailure(old, using: row)
                    } else {
                        Self.merge(row, into: &telemetry)
                    }
                } else {
                    Self.merge(row, into: &all)
                }
            }
            for (old, claims) in entry.aliasClaims { aliases[old, default: []].formUnion(claims) }
            mergeTitles(entry.titles, modified: entry.stamp.primary.modified)
        }
        let superseded = Self.promoteAliases(aliases, in: &all, telemetry: telemetry)
        // Join after selecting the transcript's counters. Otherwise a complete
        // revision from a later file can wipe out already-joined OTel evidence.
        for row in telemetry.values {
            if let old = all[row.id], old.source == "claude.assistant", old.isFailure == row.isFailure {
                all[row.id] = old.isFailure ? enrichClaudeFailure(old, using: row) : enrichClaudeTranscript(old, using: row)
            } else {
                Self.merge(row, into: &all)
            }
        }
        cache.files = nextCache
        cache.titleIndexes = nextTitleCache
        cache.codexCreatorAccounts = codexCreatorAccounts
        let requests = all.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        let groups = Dictionary(grouping: requests, by: \.agent)
        let reports = Agent.localCollectors.map { agent in
            let files = counts[agent, default: 0]
            let rows = groups[agent] ?? []
            let timed = rows.lazy.filter(\.hasCompleteTiming).count
            let estimated = rows.lazy.filter { $0.estimatedTPS != nil }.count
            let errors = discoveryErrors[agent, default: 0]
            let summary = files == 0 ? "未找到本机用量文件" : rows.isEmpty ? "文件中未找到可解析的请求记录"
                : "\(timed) / \(rows.count) 条有完整请求耗时 · \(estimated) 条可估算 TPS"
            return CollectionReport(agent: agent, files: files, requests: rows.count,
                                    note: errors == 0 ? summary : "\(summary) · \(errors) 处暂不可读")
        }
        let result = CollectionResult(requests: requests, reports: reports, supersededRequestIDs: superseded,
                                      sessionTitles: titles.mapValues(\.title))
        cache.result = result
        cache.reportFiles = counts
        cache.reportErrors = discoveryErrors
        return result
    }

    private static func promoteAliases(_ aliases: [String: Set<String>], in all: inout [String: UsageRequest],
                                       telemetry: [String: UsageRequest]) -> Set<String> {
        var reverseCounts: [String: Int] = [:]
        for targets in aliases.values {
            for id in targets { reverseCounts[id, default: 0] += 1 }
        }
        func observedSuccess(_ row: UsageRequest?) -> Bool {
            guard let row else { return false }
            return !row.isFailure && row.isValid && row.totalTokens > 0
        }
        var superseded: Set<String> = []
        for (oldID, targets) in aliases {
            guard targets.count == 1, let newID = targets.first, reverseCounts[newID] == 1,
                  observedSuccess(all[newID]) || observedSuccess(telemetry[newID]) else { continue }
            superseded.insert(oldID)
            if var provisional = all.removeValue(forKey: oldID) {
                provisional.id = newID
                Self.merge(provisional, into: &all)
            }
        }
        return superseded
    }

    private static func merge(_ row: UsageRequest, into all: inout [String: UsageRequest]) {
        guard let old = all[row.id] else { all[row.id] = row; return }
        let candidate = [row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheWriteTokens]
        let previous = [old.inputTokens, old.outputTokens, old.cacheReadTokens, old.cacheWriteTokens]
        let sameModel = row.modelIdentity == old.modelIdentity
        let resolvesUnknownModel = old.modelIdentity == "unknown" && row.modelIdentity != "unknown"
        let chooseNew: Bool
        if row.isFailure != old.isFailure {
            chooseNew = !row.isFailure
        } else if candidate == previous {
            // Only use richer metadata as a tie-breaker for equal counters.
            chooseNew = resolvesUnknownModel || (sameModel && (
                (!old.hasCompleteTiming && row.hasCompleteTiming)
                    || (old.requestedModel == "unknown" && row.requestedModel != "unknown")
                    || (old.requestedServiceTier == nil && row.requestedServiceTier != nil)
                    || (old.serviceTier == nil && row.serviceTier != nil)
            ))
        } else {
            // A cumulative revision can only increase the individual buckets.
            // Crossed counters have no ordered winner; keep the deterministic
            // first source instead of treating the greatest sum as authoritative.
            chooseNew = (sameModel || resolvesUnknownModel) && zip(candidate, previous).allSatisfy { $0.0 >= $0.1 }
        }
        all[row.id] = chooseNew ? row.preservingEvidence(from: old) : old.preservingEvidence(from: row)
    }

    private func discover(_ root: URL, agent: Agent, custom: Bool, errors: inout [Agent: Int]) -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let values = try? root.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
            if custom { errors[agent, default: 0] += 1 }
            return []
        }
        func accepts(_ file: URL, direct: Bool) -> Bool {
            switch agent {
            case .codex: return file.pathExtension == "jsonl" && file.lastPathComponent != "session_index.jsonl"
            case .claudeCode: return file.pathExtension == "jsonl"
            case .claudeDesktop:
                if file.pathExtension != "jsonl" { return false }
                return custom || direct || file.pathComponents.contains("projects")
            case .antigravity:
                if file.lastPathComponent == "transcript_full.jsonl" { return true }
                // Exclude the global summaries/cache databases and arbitrary non-conversation DBs.
                return file.pathExtension == "db" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
            case .cpa: return false
            }
        }
        if values.isRegularFile == true { return accepts(root, direct: true) ? [root] : [] }
        guard values.isDirectory == true else { return [] }
        var hadErrors = false
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
            hadErrors = true
            return true
        }) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker {
            guard let meta = try? file.resourceValues(forKeys: keys), meta.isSymbolicLink != true else {
                walker.skipDescendants()
                continue
            }
            if meta.isDirectory == true {
                // Claude Desktop has other sensitive/application state trees. Skip
                // all hidden roots except the official agent runner's .claude.
                let name = file.lastPathComponent
                if name == ".git" || name == "node_modules" || name == "tool-results" || name == "file-history"
                    || (agent == .claudeDesktop && name.hasPrefix(".") && name != ".claude") {
                    walker.skipDescendants()
                }
                continue
            }
            if meta.isRegularFile == true, accepts(file, direct: false) { files.append(file) }
        }
        if hadErrors { errors[agent, default: 0] += 1 }
        return files
    }

    private func fingerprint(_ file: URL) throws -> FileStamp {
        let fm = FileManager.default
        func stat(_ file: URL) throws -> FileVersion {
            let data = try fm.attributesOfItem(atPath: file.path)
            return FileVersion(size: (data[.size] as? NSNumber)?.uint64Value ?? 0,
                               modified: data[.modificationDate] as? Date ?? .distantPast,
                               node: (data[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }
        let hasWAL = ["db", "sqlite"].contains(file.pathExtension)
        return FileStamp(primary: try stat(file),
                         wal: hasWAL ? try? stat(URL(fileURLWithPath: file.path + "-wal")) : nil)
    }

    private func collectCodexRequestAuth(roots: [URL], cache: CollectorCache) throws -> [CodexAuthTurn: CodexAuthEvidence] {
        var snapshots: [URL: CachedCodexAuthDatabase] = [:]
        var combined: [CodexAuthTurn: CodexAuthEvidence] = [:]
        for database in codexAuthDatabases(roots: roots) {
            try Task.checkCancellation()
            do {
                let stamp = try fingerprint(database)
                let snapshot: CachedCodexAuthDatabase
                if let old = cache.codexAuthDatabases[database], old.stamp == stamp {
                    snapshot = old
                } else {
                    snapshot = CachedCodexAuthDatabase(stamp: stamp, turns: try collectCodexAuthEvidence(database))
                }
                snapshots[database] = snapshot
                for (turn, evidence) in snapshot.turns {
                    combined[turn] = combined[turn].map { $0.combined(with: evidence) } ?? evidence
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Optional metadata: an unavailable trace database must not stop usage collection.
                // Do not cache a failed read; retry even when its file stamp is unchanged.
                continue
            }
        }
        cache.codexAuthDatabases = snapshots
        return combined
    }
}

private struct CollectorKey: Hashable { let agent: Agent; let path: String }
private struct FileVersion: Equatable { let size: UInt64; let modified: Date; let node: UInt64 }
private struct FileStamp: Equatable { let primary: FileVersion; let wal: FileVersion? }
private struct CachedCollection {
    let stamp: FileStamp
    let requests: [UsageRequest]
    let titles: [String: SessionTitleEvidence]
    let aliasClaims: [String: Set<String>]
    let codexThreadID: String?
    let codexAuthByTurn: [CodexAuthTurn: CodexAuthEvidence]
    let codexCreator: CodexCreatorIdentity?
}
private struct CachedTitleIndex { let stamp: FileStamp; let titles: [String: SessionTitleEvidence] }
private struct CachedCodexAuthDatabase { let stamp: FileStamp; let turns: [CodexAuthTurn: CodexAuthEvidence] }
private final class CollectorCache: @unchecked Sendable {
    let lock = NSLock()
    var deviceID: String?
    var files: [CollectorKey: CachedCollection] = [:]
    var titleIndexes: [URL: CachedTitleIndex] = [:]
    var codexAuthDatabases: [URL: CachedCodexAuthDatabase] = [:]
    var codexCreatorAccounts = CodexCreatorAccounts()
    var result: CollectionResult?
    var reportFiles: [Agent: Int] = [:]
    var reportErrors: [Agent: Int] = [:]
}

typealias CollectorJSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> CollectorJSON? { self[key] as? CollectorJSON }
    func text(_ key: String) -> String? { collectorText(self[key] as? String) }
    func number(_ key: String) -> Int64? {
        guard let value = self[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let n = value.doubleValue
        guard n.isFinite, n.rounded(.towardZero) == n, n >= 0, n <= 1_000_000_000_000 else { return nil }
        return value.int64Value
    }
    func milliseconds(_ key: String) -> Double? {
        guard let value = self[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let ms = value.doubleValue
        return ms.isFinite && ms > 0 && ms <= 86_400_000 ? ms : nil
    }
}

func collectorText(_ value: String?, limit: Int = 512) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty, value.utf8.count <= limit, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
    return value
}

func collectorID(_ parts: String...) -> String {
    SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
}

struct CollectorDates {
    let fraction = ISO8601DateFormatter()
    let whole = ISO8601DateFormatter()
    init() {
        fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
    }

    func parse(_ text: String?) -> Date? {
        guard let text, text.utf8.count <= 50 else { return nil }
        return fraction.date(from: text) ?? whole.date(from: text)
    }
}

enum CollectorReadError: Error { case unreadable, schema, malformedMetadata }

// getline avoids a Swift allocation and JSON parse for each irrelevant transcript line.
func readCollectorLines(_ url: URL, markers: [String] = [],
                        _ consume: (CollectorJSON) -> Void) throws {
    try readNumberedCollectorLines(url, markers: markers) { object, _ in consume(object) }
}

func readNumberedCollectorLines(_ url: URL, markers: [String] = [],
                                _ consume: (CollectorJSON, Int) -> Void) throws {
    // Never follow the final path component if another app rotates a source into a symlink.
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw CollectorReadError.unreadable }
    var statBuffer = stat()
    guard fstat(fd, &statBuffer) == 0, statBuffer.st_mode & S_IFMT == S_IFREG,
          let stream = fdopen(fd, "r") else {
        close(fd)
        throw CollectorReadError.unreadable
    }
    defer { fclose(stream) }
    var line: UnsafeMutablePointer<CChar>?
    var capacity = 0
    defer { free(line) }
    var counter = 0
    while true {
        let bytes = getline(&line, &capacity, stream)
        if bytes < 0 {
            if ferror(stream) != 0 { throw CollectorReadError.unreadable }
            break
        }
        counter += 1
        if counter % 512 == 0 { try Task.checkCancellation() }
        guard let line, bytes <= 32 * 1024 * 1024,
              line[bytes - 1] == 10 || feof(stream) != 0 else { continue }
        if !markers.isEmpty && !markers.contains(where: { strstr(line, $0) != nil }) { continue }
        autoreleasepool {
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(line), count: bytes, deallocator: .none)
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? CollectorJSON {
                consume(object, counter)
            }
        }
    }
}

// Explicit request-scoped timing only. Top-level turn durations, TTFT, and
// elapsed time between adjacent messages cannot establish a model request time.
func requestTiming(_ row: CollectorJSON, dates: CollectorDates) -> (Double?, String?) {
    for field in ["request_duration_ms", "requestDurationMs", "request_latency_ms"] {
        if let ms = row.milliseconds(field) { return (ms, "native-request-duration") }
    }
    if let start = dates.parse(row.text("request_started_at") ?? row.text("requestStartedAt")),
       let end = dates.parse(row.text("request_completed_at") ?? row.text("requestCompletedAt")) {
        let ms = end.timeIntervalSince(start) * 1_000
        if ms > 0, ms <= 86_400_000 { return (ms, "native-request-boundaries") }
    }
    return (nil, nil)
}

/// A session interval is separate from request timing, and never promoted to it.
func sessionIntervalMS(from start: Date?, to end: Date) -> Double? {
    guard let start else { return nil }
    // Native log stamps have millisecond precision. Rounding avoids a valid
    // interval of exactly one second falling just below the TPS sample gate.
    let elapsed = (end.timeIntervalSince(start) * 1_000).rounded()
    return elapsed > 0 && elapsed < 7_200_000 ? elapsed : nil
}

func collectorTier(_ raw: String?) -> String? {
    switch raw?.lowercased() {
    case "priority", "fast": return "priority"
    case "ultrafast", "ultra-fast", "ultra_fast": return "ultrafast"
    case "standard", "default", "normal": return "default"
    case "auto": return "auto"
    case "flex": return "flex"
    case "scale": return "scale"
    default: return nil
    }
}
