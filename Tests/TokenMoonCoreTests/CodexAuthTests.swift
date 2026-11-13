// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import Testing
@testable import TokenMoonCore

@Test func codexAuthUsesExactTurnAndThreadAndInvalidatesOnWALConflicts() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = folder.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions/2026/11/10")
    let archive = home.appendingPathComponent("archived_sessions")
    let unrelated = folder.appendingPathComponent("unrelated/sessions")
    for directory in [sessions, archive, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: folder) }

    let db = try openCodexAuthFixture(home.appendingPathComponent("logs_2.sqlite"))
    defer { sqlite3_close(db) }
    // The two native threads report under the same parent session, and use the
    // same turn ID in this fixture. Neither dimension alone proves a match.
    let first = sessions.appendingPathComponent("rollout-first.jsonl")
    let second = archive.appendingPathComponent("rollout-second.jsonl")
    let copied = unrelated.appendingPathComponent("copy.jsonl")
    try writeCodexAuthTranscript(first, thread: "thread-one", response: "resp-one", tokens: 1)
    try writeCodexAuthTranscript(second, thread: "thread-two", response: "resp-two", tokens: 2)
    try writeCodexAuthTranscript(copied, thread: "thread-one", response: "resp-one", tokens: 1)
    try insertCodexAuthFixture(db, thread: "thread-one", trace: authTrace("thread-one", mode: "Chatgpt"))
    try insertCodexAuthFixture(db, thread: "thread-one", trace: authTrace("thread-one", mode: "Chatgpt"))
    // Valid-looking rows on another turn, a mismatched thread, or a warmup
    // must not change the matching result or fill the other thread's request.
    try insertCodexAuthFixture(db, thread: "thread-one", trace: authTrace("thread-one", turn: "older-turn", mode: "ApiKey"))
    try insertCodexAuthFixture(db, thread: "thread-one", trace: authTrace("thread-two", mode: "ApiKey"))
    try insertCodexAuthFixture(db, thread: "thread-two", trace: authTrace("thread-two", mode: "ApiKey", warmup: true))
    try insertCodexAuthFixture(db, thread: "thread-two", trace: "session_loop{thread_id=thread-two}: auth_mode=Some(ApiKey)")
    try insertCodexAuthFixture(db, thread: "thread-two", target: "other_trace", trace: authTrace("thread-two", mode: "ApiKey"))

    let discovered = codexAuthDatabases(roots: [sessions, archive])
    let file = try #require(discovered.first)
    #expect(try collectCodexAuthEvidence(file)[CodexAuthTurn(threadID: "thread-one", turnID: "shared-turn")] == .method("chatgpt"))
    let collector = UsageCollectors()
    func scan(_ paths: [URL]) throws -> [UsageRequest] {
        let roots = Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, $0 == .codex ? paths : []) })
        return try collector.scan(deviceID: "codex-auth-test-device", roots: roots).requests
    }
    let firstScan = try scan([sessions, archive])
    #expect(firstScan.count == 2)
    #expect(firstScan.first { $0.outputTokens == 1 }?.loginMethod == "chatgpt")
    #expect(firstScan.first { $0.outputTokens == 2 }?.loginMethod == nil)
    #expect(try scan([sessions, archive]) == firstScan)

    // Append only to WAL with the writer still open. No transcript bytes change.
    try insertCodexAuthFixture(db, thread: "thread-two", trace: authTrace("thread-two", mode: "ApiKey"))
    try insertCodexAuthFixture(db, thread: "thread-one", trace: authTrace("thread-one", mode: "ApiKey"))
    let secondScan = try scan([sessions, archive])
    #expect(secondScan.count == 2)
    let conflicting = try #require(secondScan.first { $0.outputTokens == 1 })
    #expect(conflicting.loginMethod == nil && conflicting.loginMethodEvidence == .conflicting)
    let previouslyAttributed = try #require(firstScan.first { $0.outputTokens == 1 })
    let reconciled = conflicting.preservingEvidence(from: previouslyAttributed)
    #expect(reconciled.loginMethod == nil && reconciled.loginMethodEvidence == .conflicting)
    #expect(secondScan.first { $0.outputTokens == 2 }?.loginMethod == "api_key")
    // Selecting a different home must not fall back to the previous database.
    let scoped = try scan([unrelated])
    #expect(scoped.count == 1 && scoped.first?.loginMethod == nil)
}

private func writeCodexAuthTranscript(_ file: URL, thread: String, response: String, tokens: Int) throws {
    try """
    {"timestamp":"2026-11-10T08:00:00Z","type":"session_meta","payload":{"id":"\(thread)","session_id":"shared-session","model_provider":"openai"}}
    {"timestamp":"2026-11-10T08:00:01Z","type":"turn_context","payload":{"turn_id":"shared-turn","model":"gpt-fixture"}}
    {"timestamp":"2026-11-10T08:00:05Z","type":"token_usage_record","payload":{"response_id":"\(response)","thread_id":"\(thread)","session_id":"shared-session","turn_id":"shared-turn","usage":{"input_tokens":1,"output_tokens":\(tokens)}}}
    """.write(to: file, atomically: true, encoding: .utf8)
}

private func authTrace(_ thread: String, turn: String = "shared-turn", mode: String, warmup: Bool = false) -> String {
    """
    session_loop{thread_id=\(thread)}:turn{thread.id=\(thread) turn.id=\(turn)}:run_turn{conversation.id=shared-session turn.id=\(turn)}:run_sampling_request{turn_id=\(turn)}:stream_request:model_client.stream_responses_websocket{websocket.warmup=\(warmup) api.path="/responses"}:responses_websocket.stream_request{transport="responses_websocket" api.path="/responses"}: endpoint="/responses" auth_header_attached=true auth_header_name="authorization" auth_mode="\(mode)" auth_connection_reused="true"
    """
}

private func openCodexAuthFixture(_ file: URL) throws -> OpaquePointer {
    var db: OpaquePointer?
    guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }
        throw CocoaError(.fileWriteUnknown)
    }
    let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE logs (thread_id TEXT, target TEXT, feedback_log_body TEXT);
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw CocoaError(.fileWriteUnknown)
    }
    return db
}

private func insertCodexAuthFixture(_ db: OpaquePointer, thread: String, target: String = "feedback_tags", trace: String) throws {
    func literal(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    let sql = "INSERT INTO logs VALUES (\(literal(thread)), \(literal(target)), \(literal(trace)))"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
}
