// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import SQLite3

struct CodexAuthTurn: Hashable, Sendable {
    let threadID: String
    let turnID: String
}

/// Authentication mode recorded by a native Codex Responses request trace.
/// An unsupported or contradictory trace prevents attributing the whole turn.
enum CodexAuthEvidence: Equatable, Sendable {
    case method(String)
    case ambiguous

    func combined(with other: Self) -> Self {
        self == other ? self : .ambiguous
    }
}

/// Use only the database alongside a selected Codex transcript root. In a
/// standard home, `sessions` and `archived_sessions` share one database.
func codexAuthDatabases(roots: [URL]) -> [URL] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    var paths: Set<URL> = []
    for root in roots where root.isFileURL {
        let url = root.standardizedFileURL
        guard let info = try? url.resourceValues(forKeys: keys), info.isSymbolicLink != true else { continue }
        let directory: URL
        if info.isDirectory == true {
            directory = url
        } else if info.isRegularFile == true, url.pathExtension == "jsonl" {
            directory = url.deletingLastPathComponent()
        } else {
            continue
        }
        var cursor = directory
        while cursor.path != "/" && !["sessions", "archived_sessions"].contains(cursor.lastPathComponent) {
            cursor.deleteLastPathComponent()
        }
        let home = cursor.path == "/" ? directory : cursor.deletingLastPathComponent()
        let database = home.appendingPathComponent("logs_2.sqlite").standardizedFileURL
        guard let info = try? database.resourceValues(forKeys: keys),
              info.isRegularFile == true, info.isSymbolicLink != true else { continue }
        paths.insert(database)
    }
    return paths.sorted { $0.path < $1.path }
}

func collectCodexAuthEvidence(_ file: URL) throws -> [CodexAuthTurn: CodexAuthEvidence] {
    var handle: OpaquePointer?
    // macOS can spell a selected directory with a system alias such as
    // /var. Resolve its parent without following a symlink at the DB itself.
    guard let parent = realpath(file.deletingLastPathComponent().path, nil) else {
        throw CollectorReadError.unreadable
    }
    defer { free(parent) }
    let path = String(cString: parent) + "/" + file.lastPathComponent
    let opened = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
    defer { if let handle { sqlite3_close(handle) } }
    guard opened == SQLITE_OK, let handle else { throw CollectorReadError.unreadable }
    sqlite3_busy_timeout(handle, 100)
    guard sqlite3_exec(handle, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF;", nil, nil, nil) == SQLITE_OK else {
        throw CollectorReadError.unreadable
    }
    // A single SELECT gives a consistent view of the database plus committed WAL frames.
    let sql = """
        SELECT thread_id, feedback_log_body FROM logs
        WHERE target = 'feedback_tags' AND thread_id IS NOT NULL
          AND instr(feedback_log_body, ' auth_header_attached=') > 0
          AND instr(feedback_log_body, 'api.path="/responses"') > 0
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw CollectorReadError.unreadable
    }
    defer { sqlite3_finalize(statement) }
    var turns: [CodexAuthTurn: CodexAuthEvidence] = [:]
    while true {
        try Task.checkCancellation()
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return turns
        case SQLITE_ROW:
            guard let thread = boundedCodexAuthText(statement, column: 0, limit: 128),
                  let body = boundedCodexAuthText(statement, column: 1, limit: 32_768),
                  let (turn, evidence) = CodexAuthTrace.read(thread: thread, body: body) else { continue }
            turns[turn] = turns[turn].map { $0.combined(with: evidence) } ?? evidence
        default: throw CollectorReadError.unreadable
        }
    }
}

private func boundedCodexAuthText(_ statement: OpaquePointer, column: Int32, limit: Int) -> String? {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
          let address = sqlite3_column_text(statement, column) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, count <= limit else { return nil }
    return String(bytes: UnsafeBufferPointer(start: address, count: count), encoding: .utf8)
}

private enum CodexAuthTrace {
    private static let turn = regex(#"(?:^|[\s{,])(?:turn\.id|turn_id)=(?:"([A-Za-z0-9_-]{1,128})"|([A-Za-z0-9_-]{1,128}))(?=[\s},]|$)"#)
    private static let thread = regex(#"(?:^|[\s{,])(?:thread\.id|thread_id)=(?:"([A-Za-z0-9_-]{1,128})"|([A-Za-z0-9_-]{1,128}))(?=[\s},]|$)"#)
    private static let auth = regex(#"\}: endpoint="/responses" auth_header_attached=(true|false) auth_header_name="([^"]*)" auth_mode="([^"]*)"(?=\s|$)"#)

    static func read(thread rowThread: String, body: String) -> (CodexAuthTurn, CodexAuthEvidence)? {
        let span = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let fields = auth.firstMatch(in: body, range: span),
              let tail = Range(fields.range, in: body) else { return nil }
        let trace = String(body[..<tail.lowerBound])
        // Skip startup/settings traces, warmup, and connection-only events.
        guard trace.contains("api.path=\"/responses\""),
              trace.contains(":responses_websocket.stream_request{") || trace.contains(":responses_http.stream_request{"),
              !trace.contains("websocket.warmup=true") else { return nil }
        let embeddedThreads = values(thread, in: trace)
        guard !embeddedThreads.isEmpty, embeddedThreads.allSatisfy({ $0 == rowThread }) else { return nil }
        let turns = values(turn, in: trace)
        guard let id = turns.first, turns.allSatisfy({ $0 == id }) else { return nil }
        let key = CodexAuthTurn(threadID: rowThread, turnID: id)
        guard capture(fields, at: 1, in: body) == "true",
              let header = capture(fields, at: 2, in: body)?.lowercased(),
              ["authorization", "api-key", "x-api-key"].contains(header),
              let mode = capture(fields, at: 3, in: body)?.lowercased() else { return (key, .ambiguous) }
        let method: String
        switch mode {
        case "chatgpt": method = "chatgpt"
        case "apikey", "api_key": method = "api_key"
        case "chatgptauthtokens", "chatgpt_auth_tokens": method = "chatgpt_auth_tokens"
        default: return (key, .ambiguous)
        }
        return (key, .method(method))
    }

    private static func values(_ expression: NSRegularExpression, in text: String) -> [String] {
        expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            capture($0, at: 1, in: text) ?? capture($0, at: 2, in: text)
        }
    }

    private static func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // All patterns are fixed and exercised by the collector fixtures.
        try! NSRegularExpression(pattern: pattern)
    }
}
