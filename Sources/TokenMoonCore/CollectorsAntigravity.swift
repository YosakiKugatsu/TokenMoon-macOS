// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import SQLite3

private enum GravityFlavor: String {
    case desktop, insiders, cli

    init(_ url: URL) {
        if url.pathComponents.contains("antigravity-cli") { self = .cli }
        else if url.pathComponents.contains("antigravity-insiders") { self = .insiders }
        else { self = .desktop }
    }
}

func collectAntigravity(_ url: URL, device: String) throws -> [UsageRequest] {
    if url.pathExtension == "db" {
        return try GravityDatabase.read(url, device: device, flavor: GravityFlavor(url)).requests
    }
    // <store>/brain/<conversation>/.system_generated/logs/transcript_full.jsonl
    let sessionFolder = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sessionID = sessionFolder.lastPathComponent
    guard UUID(uuidString: sessionID) != nil else { return [] }
    let store = sessionFolder.deletingLastPathComponent().deletingLastPathComponent()
    let database = store.appendingPathComponent("conversations/\(sessionID).db")
    var models: [Int64: String] = [:]
    if FileManager.default.fileExists(atPath: database.path) {
        do {
            let native = try GravityDatabase.read(database, device: device, flavor: .cli)
            if !native.requests.isEmpty {
                return try enrichGravityCLIIdentity(native.requests, from: url, sessionID: sessionID)
            }
            models = native.models
        } catch is CancellationError {
            throw CancellationError()
        } catch { /* Older CLI versions only record tokens in the transcript. */ }
    }

    let dates = CollectorDates()
    var rows: [Int64: UsageRequest] = [:]
    try readCollectorLines(url, markers: ["\"MODEL\""]) { step in
        guard step.text("source") == "MODEL", let index = step.number("step_index"),
              let at = dates.parse(step.text("created_at")),
              let input = step.number("input_tokens"), let output = step.number("output_tokens") else { return }
        let read = step.number("cache_read_tokens") ?? 0
        let write = step.number("cache_write_tokens") ?? 0
        guard input + output + read + write > 0 else { return }
        let status = step.text("status")
        if status == "RUNNING" || status == "PENDING" { return }
        let (duration, timing) = requestTiming(step, dates: dates)
        let sent = step.text("model") ?? models[index]
        rows[index] = UsageRequest(id: collectorID("antigravity-cli", sessionID, "step", String(index)), sessionID: sessionID,
                                   deviceID: device, agent: .antigravity, timestamp: at,
                                   requestedModel: step.text("requested_model") ?? gravityModelFamily(sent) ?? "unknown",
                                   sentModel: sent, provider: step.text("provider"),
                                   providerID: step.text("provider_id"), account: step.text("account"), loginMethod: step.text("login_method"),
                                   reasoningEffort: step.text("reasoning_effort"), serviceTier: collectorTier(step.text("service_tier")),
                                   requestedServiceTier: collectorTier(step.text("requested_service_tier")),
                                   status: status == "DONE" ? "success" : status == "ERROR" ? "failed" : "unknown",
                                   durationMS: duration, timingSource: timing,
                                   inputTokens: input, outputTokens: output, cacheReadTokens: read, cacheWriteTokens: write,
                                   reasoningTokens: step.number("reasoning_tokens").flatMap { $0 <= output ? $0 : nil },
                                   source: "antigravity.cli.transcript", channel: step.text("channel"))
    }
    return Array(rows.values)
}

private func enrichGravityCLIIdentity(
    _ requests: [UsageRequest], from transcript: URL, sessionID: String
) throws -> [UsageRequest] {
    // SQLite and the transcript use the same step ID for CLI requests.
    // Keep native counters, but do not discard explicit step identity fields
    // in the transcript just because the matching DB has usage data.
    let nativeIDs = Set(requests.map(\.id))
    var accounts: [String: Set<String>] = [:]
    var logins: [String: Set<String>] = [:]
    do {
        try readCollectorLines(transcript, markers: ["\"account\"", "\"login_method\""]) { step in
            guard step.text("source") == "MODEL", let index = step.number("step_index"),
                  step.text("status") != "RUNNING", step.text("status") != "PENDING" else { return }
            let id = collectorID("antigravity-cli", sessionID, "step", String(index))
            guard nativeIDs.contains(id) else { return }
            if let account = step.text("account") { accounts[id, default: []].insert(account) }
            if let login = step.text("login_method") { logins[id, default: []].insert(login) }
        }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return requests
    }
    return requests.map { request in
        let observedAccounts = accounts[request.id] ?? []
        let observedLogins = logins[request.id] ?? []
        guard observedAccounts.count <= 1, observedLogins.count <= 1 else { return request }
        var enriched = request
        enriched.account = request.account ?? observedAccounts.first
        enriched.loginMethod = request.loginMethod ?? observedLogins.first
        return enriched
    }
}

private func gravityModelFamily(_ model: String?) -> String? {
    guard let model else { return nil }
    let parts = model.split(separator: "-")
    // Some Gemini names are deployment IDs, for example gemini-3.8-flash-n.
    if model.hasPrefix("gemini-"), parts.count > 2, let tail = parts.last, tail.utf8.count == 1,
       let byte = tail.utf8.first, byte >= 97 && byte <= 122 {
        return String(model.dropLast(2))
    }
    return model
}

private enum GravityDatabase {
    static func read(_ url: URL, device: String, flavor: GravityFlavor) throws -> (requests: [UsageRequest], models: [Int64: String]) {
        let session = url.deletingPathExtension().lastPathComponent
        return try withDB(url) { db in
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw CollectorReadError.unreadable }
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            var byGenerator: [Int64: String] = [:]
            var byStep: [Int64: String] = [:]
            try query(db, "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx") { statement in
                guard let data = blob(statement, column: 1), let gen = try? GravityProto.generator(data) else { return }
                byGenerator[sqlite3_column_int64(statement, 0)] = gen.name
                for step in gen.indices { byStep[step] = gen.name }
            }
            var requests: [String: UsageRequest] = [:]
            try query(db, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx") { statement in
                let index = sqlite3_column_int64(statement, 0)
                guard let data = blob(statement, column: 1), let step = try? GravityProto.step(data) else { return }
                let model = byStep[index] ?? byGenerator[step.generator]
                let key = step.response ?? step.message
                // CLI IDs prefer the step index, the common identity between
                // older transcripts and current CLI conversation databases.
                let id = collectorID("antigravity-\(flavor.rawValue)", session, flavor == .cli || key == nil ? "step" : "response",
                                     flavor == .cli ? String(index) : key ?? String(index))
                let collapse = key.map { "id:\($0)" } ?? "step:\(index)"
                requests[collapse] = UsageRequest(id: id, sessionID: flavor == .insiders ? "insiders:\(session)" : session,
                                                  deviceID: device, agent: .antigravity, timestamp: step.at,
                                                  requestedModel: gravityModelFamily(model) ?? "unknown", sentModel: model,
                                                  status: "success", inputTokens: step.input, outputTokens: step.output,
                                                  cacheReadTokens: step.read, cacheWriteTokens: step.write,
                                                  source: "antigravity.\(flavor.rawValue).sqlite")
            }
            return (Array(requests.values), byStep)
        }
    }

    private static func withDB<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
            $0.isRegularFile == true && $0.isSymbolicLink != true
        }) == true else { throw CollectorReadError.unreadable }
        var db: OpaquePointer?
        // macOS's /var and /tmp are system symlinks. Canonicalize parents
        // while retaining SQLite's no-follow check on the database itself.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw CollectorReadError.unreadable }
        defer { free(parent) }
        let path = String(cString: parent) + "/" + url.lastPathComponent
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let db { sqlite3_close(db) } }
        guard result == SQLITE_OK, let db else { throw CollectorReadError.unreadable }
        sqlite3_busy_timeout(db, 200)
        // Prevent vendor schema changes or views from invoking unsafe SQL.
        sqlite3_exec(db, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF;", nil, nil, nil)
        return try body(db)
    }

    private static func query(_ db: OpaquePointer, _ sql: String,
                              _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectorReadError.schema
        }
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                count += 1
                if count % 128 == 0 { try Task.checkCancellation() }
                try body(statement)
            case SQLITE_DONE: return
            default: throw CollectorReadError.unreadable
            }
        }
    }

    private static func blob(_ statement: OpaquePointer, column: Int32) -> Data? {
        let bytes = Int(sqlite3_column_bytes(statement, column))
        guard bytes > 0, bytes <= 32 * 1024 * 1024, let address = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: bytes, deallocator: .none)
    }
}

// The schema is vendor-private. Restrict parsing to observed metadata fields;
// encrypted step_payload / message data are never queried.
private enum GravityProto {
    struct Step {
        let at: Date
        let generator: Int64
        let input: Int64
        let output: Int64
        let write: Int64
        let read: Int64
        let response: String?
        let message: String?
    }

    static func step(_ data: Data) throws -> Step? {
        var at: Date?
        var generator: Int64 = 0
        var tokens: [Int: Int64] = [:]
        var response: String?
        var message: String?
        try walk(data) { field, _, payload in
            guard let payload else { return }
            switch field {
            case 1:
                var sec: UInt64 = 0
                var nano: UInt64 = 0
                try walk(payload) { n, value, _ in
                    if n == 1, let value { sec = value }
                    if n == 2, let value { nano = value }
                }
                if sec > 0, sec <= 253_402_300_799, nano < 1_000_000_000 {
                    at = Date(timeIntervalSince1970: Double(sec) + Double(nano) / 1_000_000_000)
                }
            case 9:
                try walk(payload) { n, value, raw in
                    if (2...5).contains(n), let value, value <= 1_000_000_000_000 {
                        tokens[n] = Int64(value)
                    } else if n == 7, let raw { message = text(raw) }
                    else if n == 11, let raw { response = text(raw) }
                }
            case 20:
                try walk(payload) { n, value, _ in
                    if n == 3, let value, value <= Int64.max { generator = Int64(value) }
                }
            default: break
            }
        }
        guard let at, tokens.values.contains(where: { $0 > 0 }) else { return nil }
        return Step(at: at, generator: generator, input: tokens[2] ?? 0, output: tokens[3] ?? 0,
                    write: tokens[4] ?? 0, read: tokens[5] ?? 0, response: response, message: message)
    }

    static func generator(_ data: Data) throws -> (name: String, indices: [Int64])? {
        var names: [Int: String] = [:]
        var indices: [Int64] = []
        try walk(data) { field, value, payload in
            switch field {
            case 1:
                if let payload {
                    try walk(payload) { n, _, raw in
                        if n == 19 || n == 21 || n == 22, let raw { names[n] = text(raw) }
                    }
                }
            case 2:
                if let value, value <= Int64.max { indices.append(Int64(value)) }
                if let payload {
                    try payload.withUnsafeBytes { raw in
                        var cursor = 0
                        while cursor < raw.count && indices.count < 100_000 {
                            let n = try varint(raw, cursor: &cursor)
                            if n <= Int64.max { indices.append(Int64(n)) }
                        }
                    }
                }
            default: break
            }
        }
        return (names[19] ?? names[21] ?? names[22]).map { ($0, indices) }
    }

    private static func text(_ data: Data) -> String? {
        guard data.count <= 512 else { return nil }
        return collectorText(String(data: data, encoding: .utf8))
    }

    private static func varint(_ raw: UnsafeRawBufferPointer, cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard cursor < raw.count else { throw CollectorReadError.malformedMetadata }
            let b = raw[cursor]
            cursor += 1
            if shift == 63, b > 1 { throw CollectorReadError.malformedMetadata }
            result |= UInt64(b & 127) << shift
            if b < 128 { return result }
        }
        throw CollectorReadError.malformedMetadata
    }

    private static func walk(_ data: Data, _ field: (Int, UInt64?, Data?) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            var cursor = 0
            while cursor < raw.count {
                let tag = try varint(raw, cursor: &cursor)
                guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw CollectorReadError.malformedMetadata }
                let number = Int(tag >> 3)
                switch tag & 7 {
                case 0:
                    try field(number, varint(raw, cursor: &cursor), nil)
                case 1, 5:
                    cursor += tag & 7 == 1 ? 8 : 4
                    guard cursor <= raw.count else { throw CollectorReadError.malformedMetadata }
                case 2:
                    let size = try varint(raw, cursor: &cursor)
                    guard size <= raw.count - cursor, let base = raw.baseAddress else { throw CollectorReadError.malformedMetadata }
                    let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: cursor)),
                                     count: Int(size), deallocator: .none)
                    try field(number, nil, slice)
                    cursor += Int(size)
                default:
                    throw CollectorReadError.malformedMetadata
                }
            }
        }
    }
}
