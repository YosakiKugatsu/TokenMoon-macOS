// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import Testing
@testable import TokenMoonCore

private func withIdentityFixture(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test func claudeFailureUsesActualHTTPAndExactRequestMetadata() throws {
    try withIdentityFixture { root in
        let log = root.appendingPathComponent("session.jsonl")
        try """
        {"type":"assistant","sessionId":"session","requestId":"matched","timestamp":"2026-11-10T08:00:00Z","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","message":{"id":"a","model":"<synthetic>","content":[{"type":"text","text":"fixture synthetic body must not survive"}]}}
        {"type":"assistant","sessionId":"session","requestId":"unmatched","timestamp":"2026-11-10T08:00:01Z","isApiErrorMessage":true,"apiErrorStatus":404,"error":"not_found_error","message":{"id":"b","model":"<synthetic>"}}
        {"type":"assistant","sessionId":"session","requestId":"explicit","timestamp":"2026-11-10T08:00:02Z","isApiErrorMessage":true,"apiErrorStatus":529,"apiErrorParams":{"model":"claude-haiku-4-5","message":"Provider overloaded."},"message":{"id":"c","model":"<synthetic>"}}
        {"type":"assistant","sessionId":"session","requestId":"success","timestamp":"2026-11-10T08:00:03Z","httpStatusCode":201,"message":{"id":"d","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":21}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let otlp = root.appendingPathComponent("session.otlp.jsonl")
        func event(_ fields: [String: String]) -> [String: Any] {
            let attributes = fields.merging([
                "event.name": "api_error", "event.timestamp": "2026-11-10T08:00:00Z",
                "session.id": "session"
            ]) { existing, _ in existing }
            return ["attributes": attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] }]
        }
        let envelope: [String: Any] = [
            "resourceLogs": [["scopeLogs": [["logRecords": [
                event(["request_id": "matched", "model": "claude-opus-5-5", "status_code": "429",
                       "error": "Quota exhausted. Authorization: Bearer fixture-secret-do-not-export"]),
                event(["request_id": "different", "model": "claude-sonnet-4-6", "status_code": "401",
                       "error": "Access denied for sk-fixture12345"]),
                event(["request_id": "success", "model": "claude-opus-5-5", "status_code": "500", "error": "fixture retry"])
            ]]]]]
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: otlp)
        let roots = Dictionary(uniqueKeysWithValues: Agent.localCollectors.map { ($0, $0 == .claudeCode ? [root] : []) })
        let rows = try UsageCollectors().scan(deviceID: "fixture", roots: roots).requests
        let matched = try #require(rows.first { $0.httpStatusCode == 429 })
        #expect(matched.requestedModel == "claude-opus-5-5")
        #expect(matched.message == "Quota exhausted. [已隐藏]")
        #expect(rows.first { $0.httpStatusCode == 404 }?.requestedModel == "unknown")
        #expect(rows.first { $0.httpStatusCode == 404 }?.message == "not_found_error")
        #expect(rows.first { $0.httpStatusCode == 529 }?.requestedModel == "claude-haiku-4-5")
        #expect(rows.first { $0.httpStatusCode == 529 }?.message == "Provider overloaded.")
        #expect(rows.first { $0.httpStatusCode == 401 }?.message == "Access denied for [已隐藏]")
        #expect(rows.first { $0.httpStatusCode == 201 }?.message == nil)
        #expect(rows.count == 5)
        #expect(collectorFailureMessage(#"API Error: {"error":{"message":"Busy","type":"overloaded_error"},"messages":["fixture body"]}"#) == "Busy")
        #expect(collectorFailureMessage("Raw request body: fixture body") == nil)
    }
}

@Test func claudeTelemetryUsesIdentityFromTheMatchingRequest() throws {
    try withIdentityFixture { root in
        let log = root.appendingPathComponent("session.jsonl")
        try """
        {"type":"assistant","entrypoint":"claude-desktop","sessionId":"s","requestId":"email","timestamp":"2026-11-10T08:00:00Z","message":{"id":"msg1","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":21}}}
        {"type":"assistant","entrypoint":"claude-desktop","sessionId":"s","requestId":"uuid","timestamp":"2026-11-10T08:00:01Z","message":{"id":"msg2","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":22}}}
        {"type":"assistant","entrypoint":"claude-desktop","sessionId":"s","requestId":"gateway","timestamp":"2026-11-10T08:00:02Z","message":{"id":"msg3","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":23}}}
        {"type":"assistant","entrypoint":"claude-desktop","sessionId":"s","requestId":"install","timestamp":"2026-11-10T08:00:03Z","message":{"id":"msg4","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":24}}}
        {"type":"assistant","entrypoint":"claude-desktop","sessionId":"s","requestId":"unmatched","timestamp":"2026-11-10T08:00:04Z","message":{"id":"msg5","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":25}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let otlp = root.appendingPathComponent("session.otlp.jsonl")
        func attributes(_ fields: [String: String]) -> [[String: Any]] {
            fields.map { ["key": $0.key, "value": ["stringValue": $0.value]] }
        }
        func event(_ fields: [String: String]) -> [String: Any] {
            ["attributes": attributes(fields.merging([
                "event.name": "api_request", "event.timestamp": "2026-11-10T08:00:00Z", "model": "claude-opus-5-5",
                "app.entrypoint": "claude-desktop"
            ]) { provided, _ in provided })]
        }
        let envelope: [String: Any] = [
            "resourceLogs": [[
                "resource": ["attributes": attributes(["session.id": "s", "user.email": "resource@example.invalid", "auth.type": "oauth"])],
                "scopeLogs": [["logRecords": [
                    event(["gen_ai.response.id": "email", "user.email": "first@example.invalid", "auth_type": "api_key"]),
                    event(["request_id": "uuid", "user.account_uuid": "11111111-1111-4111-8111-111111111111"]),
                    event(["request_id": "gateway", "identity.source": "gateway-oidc", "user.id": "gateway-subject"]),
                    event(["request_id": "install", "user.id": "anonymous-installation"])
                ]]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: otlp)

        let collector = UsageCollectors()
        let roots = Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, $0 == .claudeCode ? [root] : []) })
        let rows = try collector.scan(deviceID: "fixture", roots: roots).requests
        #expect(rows.count == 5 && rows.allSatisfy { $0.agent == .claudeDesktop })
        let email = try #require(rows.first { $0.outputTokens == 21 })
        #expect(email.account == "first@example.invalid" && email.loginMethod == "api_key")
        let uuid = try #require(rows.first { $0.outputTokens == 22 })
        #expect(uuid.account == "11111111-1111-4111-8111-111111111111" && uuid.loginMethod == nil)
        let gateway = try #require(rows.first { $0.outputTokens == 23 })
        #expect(gateway.account == "gateway-subject" && gateway.loginMethod == "gateway-oidc")
        #expect(rows.filter { $0.outputTokens >= 24 }.allSatisfy { $0.account == nil && $0.loginMethod == nil })
    }
}

@Test func antigravityCLIEnrichesNativeUsageOnlyFromTheMatchingUnambiguousStep() throws {
    try withIdentityFixture { root in
        let store = root.appendingPathComponent("antigravity-cli")
        let session = "33333333-3333-4333-8333-333333333333"
        let logs = store.appendingPathComponent("brain/\(session)/.system_generated/logs")
        let databases = store.appendingPathComponent("conversations")
        for directory in [logs, databases] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let database = databases.appendingPathComponent("\(session).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE gen_metadata(idx INTEGER, data BLOB);
        CREATE TABLE steps(idx INTEGER, metadata BLOB);
        INSERT INTO gen_metadata VALUES (0, X'0A159A011267656D696E692D332E382D666C6173682D6E');
        INSERT INTO steps VALUES (1, X'0A0208014A0D1064181428325A056669787431');
        INSERT INTO steps VALUES (2, X'0A0208024A0D1064181E28325A056669787432');
        """
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        #expect(result == SQLITE_OK)
        let transcript = logs.appendingPathComponent("transcript_full.jsonl")
        try """
        {"source":"MODEL","status":"RUNNING","step_index":1,"account":"pending@example.invalid"}
        {"source":"MODEL","status":"DONE","step_index":1,"account":"first@example.invalid","login_method":"oauth","input_tokens":1,"output_tokens":1}
        {"source":"MODEL","status":"DONE","step_index":2,"account":"second@example.invalid","login_method":"api_key"}
        {"source":"MODEL","status":"DONE","step_index":2,"account":"third@example.invalid","login_method":"oauth"}
        {"source":"MODEL","status":"DONE","step_index":99,"account":"unmatched@example.invalid"}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let rows = try collectAntigravity(transcript, device: "fixture")
        #expect(rows.count == 2)
        let first = try #require(rows.first { $0.outputTokens == 20 })
        #expect(first.account == "first@example.invalid" && first.loginMethod == "oauth")
        #expect(first.source == "antigravity.cli.sqlite")
        let ambiguous = try #require(rows.first { $0.outputTokens == 30 })
        #expect(ambiguous.account == nil && ambiguous.loginMethod == nil)
    }
}
