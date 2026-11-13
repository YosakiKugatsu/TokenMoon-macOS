// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3
import Testing
@testable import TokenMoonCore

private let testDevice = "example-test-mac"

private func collectorFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func only(_ agent: Agent, at roots: [URL]) -> [Agent: [URL]] {
    Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, $0 == agent ? roots : []) })
}

@Test func codexStableIdentityAndRequestOnlyTiming() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("rollout.jsonl")
        try """
        {"timestamp":"2026-11-10T08:00:00Z","type":"session_meta","payload":{"id":"session-fixture","model_provider":"openai"}}
        {"timestamp":"2026-11-10T08:00:01Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6.1-sol","service_tier":"priority"}}}
        {"timestamp":"2026-11-10T08:00:02Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-fixture"}}
        {"timestamp":"2026-11-10T08:00:02Z","type":"turn_context","payload":{"turn_id":"turn-fixture","model":"gpt-6.1-sol","effort":"ultra"}}
        {"timestamp":"2026-11-10T08:00:05Z","type":"token_usage_record","payload":{"response_id":"one","session_id":"session-fixture","turn_id":"turn-fixture","usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":60,"reasoning_output_tokens":20}}}
        {"timestamp":"2026-11-10T08:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":60},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":60}}}}
        {"timestamp":"2026-11-10T08:00:06Z","type":"token_usage_record","payload":{"response_id":"two","session_id":"session-fixture","turn_id":"turn-fixture","request_duration_ms":2000,"service_tier_served":"ultrafast","usage":{"input_tokens":450,"cached_input_tokens":400,"cache_write_input_tokens":15,"output_tokens":80}}}
        {"timestamp":"2026-11-10T08:00:07Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":5000}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let collector = UsageCollectors()
        let result = try collector.scan(deviceID: testDevice, roots: only(.codex, at: [root]))
        #expect(result.requests.count == 2)
        let first = try #require(result.requests.first)
        let last = try #require(result.requests.last)
        #expect(first.inputTokens == 100 && first.reasoningTokens == 20)
        #expect(first.requestedServiceTier == "priority" && first.serviceTier == nil && first.tps == nil)
        #expect(last.serviceTier == "ultrafast" && last.tps == 40)
        #expect(last.inputTokens == 35)
        let repeated = try collector.scan(deviceID: testDevice, roots: only(.codex, at: [root]))
        #expect(repeated.requests == result.requests)
    }
}

@Test func codexRecordsFastFromAdjacentEffectiveTurnSettings() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("rollout.jsonl")
        try """
        {"timestamp":"2026-11-10T16:47:47.771Z","type":"session_meta","payload":{"id":"live-order","model_provider":"openai"}}
        {"timestamp":"2026-11-10T16:47:47.771Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"live-order","thread_settings":{"model":"gpt-6.1-sol","service_tier":"default"}}}
        {"timestamp":"2026-11-10T16:47:47.771Z","type":"event_msg","payload":{"type":"task_started","turn_id":"fast-turn"}}
        {"timestamp":"2026-11-10T16:47:50.280Z","type":"turn_context","payload":{"turn_id":"fast-turn","model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-10T16:47:50.281Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"live-order","thread_settings":{"model":"gpt-6.1-sol","service_tier":"priority"}}}
        {"timestamp":"2026-11-10T16:47:52.199Z","type":"token_usage_record","payload":{"response_id":"one","session_id":"live-order","turn_id":"fast-turn","usage":{"input_tokens":13367,"output_tokens":11}}}
        {"timestamp":"2026-11-10T16:47:53.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"live-order","thread_settings":{"model":"gpt-6.1-sol","service_tier":"default"}}}
        {"timestamp":"2026-11-10T16:47:54.000Z","type":"token_usage_record","payload":{"response_id":"two","session_id":"live-order","turn_id":"fast-turn","usage":{"input_tokens":13367,"output_tokens":12}}}
        {"timestamp":"2026-11-10T16:47:55.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"fast-turn"}}
        {"timestamp":"2026-11-10T16:48:01.000Z","type":"turn_context","payload":{"turn_id":"standard-turn","model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-10T16:48:01.001Z","type":"world_state","payload":{}}
        {"timestamp":"2026-11-10T16:48:01.002Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"live-order","thread_settings":{"model":"gpt-6.1-sol","service_tier":"priority"}}}
        {"timestamp":"2026-11-10T16:48:02.000Z","type":"token_usage_record","payload":{"response_id":"three","session_id":"live-order","turn_id":"standard-turn","usage":{"input_tokens":13367,"output_tokens":13}}}
        {"timestamp":"2026-11-10T16:48:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"standard-turn"}}
        {"timestamp":"2026-11-10T16:48:04.000Z","type":"turn_context","payload":{"turn_id":"explicit-turn","model":"gpt-6.1-sol","service_tier":"default"}}
        {"timestamp":"2026-11-10T16:48:04.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"live-order","thread_settings":{"model":"gpt-6.1-sol","service_tier":"priority"}}}
        {"timestamp":"2026-11-10T16:48:06.000Z","type":"token_usage_record","payload":{"response_id":"four","session_id":"live-order","turn_id":"explicit-turn","usage":{"input_tokens":13367,"output_tokens":14}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let rows = try UsageCollectors().scan(deviceID: testDevice, roots: only(.codex, at: [root])).requests
        let ordered = rows.sorted { $0.outputTokens < $1.outputTokens }
        #expect(ordered.map(\.requestedServiceTier) == ["priority", "priority", "default", "default"])
        #expect(ordered.allSatisfy { $0.serviceTier == nil })
    }
}

@Test func codexKeepsCreatorSeparateFromRequestAuth() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("rollout.jsonl")
        let creator = "44444444-4444-4444-8444-444444444444"
        try """
        {"timestamp":"2026-11-10T08:00:00Z","type":"session_meta","payload":{"session_id":"root","id":"thread","creator_account_id":"\(creator)","model_provider":"openai"}}
        {"timestamp":"2026-11-10T08:00:01Z","type":"token_usage_record","payload":{"response_id":"a","session_id":"root","thread_id":"thread","turn_id":"matched","usage":{"input_tokens":10,"output_tokens":11}}}
        {"timestamp":"2026-11-10T08:00:02Z","type":"token_usage_record","payload":{"response_id":"b","session_id":"root","thread_id":"thread","turn_id":"matched","account":"caller@example.com","login_method":"api_key","usage":{"input_tokens":10,"output_tokens":12}}}
        {"timestamp":"2026-11-10T08:00:03Z","type":"token_usage_record","payload":{"response_id":"c","session_id":"root","thread_id":"thread","turn_id":"other","usage":{"input_tokens":10,"output_tokens":13}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let before = try collectCodex(log, device: testDevice).sorted { $0.timestamp < $1.timestamp }
        let after = try collectCodex(log, device: testDevice, authByTurn: [
            .init(threadID: "thread", turnID: "matched"): .method("chatgpt"),
            .init(threadID: "root", turnID: "other"): .method("api_key"),
        ]).sorted { $0.timestamp < $1.timestamp }
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.loginMethod) == ["chatgpt", "api_key", nil])
        #expect(after.map(\.account) == [nil, "caller@example.com", nil])
        #expect(after.allSatisfy { $0.sessionCreatorAccountID == creator })
        let conflicting = try collectCodex(log, device: testDevice, authByTurn: [
            .init(threadID: "thread", turnID: "matched"): .ambiguous,
        ]).sorted { $0.timestamp < $1.timestamp }
        #expect(conflicting[0].preservingEvidence(from: after[0]).loginMethod == nil)
        #expect(conflicting[0].preservingEvidence(from: after[0]).loginMethodEvidence == .conflicting)
        #expect(conflicting[1].loginMethod == "api_key")
        let portable = try JSONDecoder().decode([UsageRequest].self, from: JSONEncoder().encode(after))
        #expect(portable == after)
    }
}

@Test func codexCreatorEmailRequiresUserAndWorkspaceAndDoesNotReplaceRequestAccount() throws {
    try collectorFixture { root in
        let workspace = "55555555-5555-4555-8555-555555555555"
        let otherWorkspace = "66666666-6666-4666-8666-666666666666"
        let examples: [(String, String, String?)] = [
            ("a", workspace, "user-a"), ("b", workspace, "user-b"),
            ("c", otherWorkspace, "user-a"), ("d", workspace, nil),
        ]
        for (session, accountID, creator) in examples {
            let field = creator.map { #","creator_user_id":"\#($0)""# } ?? ""
            try """
            {"timestamp":"2026-11-10T08:00:00Z","type":"session_meta","payload":{"id":"\(session)","creator_account_id":"\(accountID)"\(field)}}
            {"timestamp":"2026-11-10T08:00:01Z","type":"token_usage_record","payload":{"response_id":"response","session_id":"\(session)","account":"request@example.com","login_method":"api_key","usage":{"input_tokens":10,"output_tokens":11}}}
            """.write(to: root.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
        }
        let collector = UsageCollectors()
        let roots = only(.codex, at: [root])
        let baseline = try collector.scan(deviceID: testDevice, roots: roots).requests.sorted { $0.sessionID < $1.sessionID }
        #expect(baseline.count == 4 && baseline.allSatisfy { $0.sessionCreatorAccountEmail == nil })

        let signedIn = CodexAccountSessionsReply.Session(userId: "user-a", email: "creator@example.com",
                                                         selectedWorkspaceAccountId: workspace.uppercased(), workspaces: [])
        let map = CodexCreatorAccounts(sessions: [signedIn])
        let enriched = try collector.scan(deviceID: testDevice, roots: roots, codexCreatorAccounts: map)
            .requests.sorted { $0.sessionID < $1.sessionID }
        #expect(enriched.map(\.id) == baseline.map(\.id))
        #expect(enriched.map(\.sessionCreatorAccountEmail) == ["creator@example.com", nil, nil, nil])
        #expect(enriched.allSatisfy { $0.account == "request@example.com" && $0.loginMethod == "api_key" })
        #expect(enriched.allSatisfy { $0.isValid })

        let replacement = CodexAccountSessionsReply.Session(userId: "user-b", email: "other@example.com",
                                                             selectedWorkspaceAccountId: workspace, workspaces: [])
        let switched = try collector.scan(deviceID: testDevice, roots: roots,
                                          codexCreatorAccounts: .init(sessions: [replacement]))
            .requests.sorted { $0.sessionID < $1.sessionID }
        #expect(switched.map(\.sessionCreatorAccountEmail) == [nil, "other@example.com", nil, nil])
        let historical = switched[0].preservingEvidence(from: enriched[0])
        #expect(historical.sessionCreatorAccountEmail == "creator@example.com")
        #expect(historical.account == "request@example.com")
        let roundTrip = try JSONDecoder().decode(UsageRequest.self, from: JSONEncoder().encode(historical))
        #expect(roundTrip == historical)

        let conflicting = CodexAccountSessionsReply.Session(userId: "user-a", email: "conflict@example.com",
                                                             selectedWorkspaceAccountId: workspace, workspaces: [])
        let conflicted = try collector.scan(deviceID: testDevice, roots: roots,
                                            codexCreatorAccounts: .init(sessions: [signedIn, conflicting]))
        #expect(conflicted.requests.allSatisfy { $0.sessionCreatorAccountEmail == nil })
    }
}

@Test func codexSubagentUsesItsThreadTierWithoutRecountingParentHistory() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("subagent-rollout.jsonl")
        try """
        {"timestamp":"2026-11-10T08:00:01Z","type":"session_meta","payload":{"id":"child-thread","session_id":"parent-session","forked_from_id":"parent-session","subagent_history_start_ordinal":4}}
        {"timestamp":"2026-11-10T08:00:01Z","type":"session_meta","payload":{"id":"parent-session","session_id":"parent-session"}}
        {"timestamp":"2026-11-10T08:00:02Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"parent-session","thread_settings":{"model":"gpt-6.1-sol","service_tier":"default"}}}
        {"timestamp":"2026-11-10T08:00:03Z","type":"token_usage_record","payload":{"response_id":"copied","session_id":"parent-session","usage":{"input_tokens":100,"output_tokens":5}}}
        {"timestamp":"2026-11-10T08:00:04Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"child-thread","thread_settings":{"model":"gpt-6.1-sol","service_tier":"priority"}}}
        {"timestamp":"2026-11-10T08:00:05Z","type":"event_msg","payload":{"type":"task_started","turn_id":"child-turn"}}
        {"timestamp":"2026-11-10T08:00:05Z","type":"turn_context","payload":{"turn_id":"child-turn","model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-10T08:00:06Z","type":"token_usage_record","payload":{"response_id":"child-response","session_id":"parent-session","thread_id":"child-thread","turn_id":"child-turn","usage":{"input_tokens":100,"output_tokens":12}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let rows = try UsageCollectors().scan(deviceID: testDevice, roots: only(.codex, at: [log])).requests
        #expect(rows.count == 1)
        let child = try #require(rows.first)
        #expect(child.id == collectorID("codex", "parent-session", "child-response"))
        #expect(child.requestedServiceTier == "priority" && child.serviceTier == nil)
    }
}

@Test func claudeBlockRevisionsJoinTelemetryByExactRequestID() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("conversation.jsonl")
        try """
        {"type":"assistant","sessionId":"session-a","timestamp":"2026-11-10T08:00:02Z","message":{"id":"message-a","model":"claude-opus-5-5","usage":{"input_tokens":20,"cache_read_input_tokens":80,"output_tokens":10,"service_tier":"standard"}}}
        {"type":"assistant","sessionId":"session-a","requestId":"req_fixture","timestamp":"2026-11-10T08:00:04Z","message":{"id":"message-a","model":"claude-opus-5-5","usage":{"input_tokens":20,"cache_read_input_tokens":80,"output_tokens":150,"speed":"standard","output_tokens_details":{"thinking_tokens":45}}}}
        {"type":"assistant","sessionId":"session-a","requestId":"req_fixture","timestamp":"2026-11-10T08:00:07Z","message":{"id":"message-a","model":"claude-opus-5-5","usage":{"input_tokens":20,"cache_read_input_tokens":80,"output_tokens":10,"service_tier":"standard"}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let otlp = root.appendingPathComponent("local.otlp.jsonl")
        try """
        {"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"session.id","value":{"stringValue":"session-a"}},{"key":"event.timestamp","value":{"stringValue":"2026-11-10T08:00:04Z"}},{"key":"request_id","value":{"stringValue":"req_fixture"}},{"key":"model","value":{"stringValue":"claude-opus-5-5"}},{"key":"speed","value":{"stringValue":"fast"}},{"key":"duration_ms","value":{"intValue":"3000"}},{"key":"input_tokens","value":{"intValue":"20"}},{"key":"output_tokens","value":{"intValue":"150"}},{"key":"cache_read_tokens","value":{"intValue":"80"}}]}]}]}]}
        """.write(to: otlp, atomically: true, encoding: .utf8)
        let collector = UsageCollectors()
        let result = try collector.scan(deviceID: testDevice, roots: only(.claudeCode, at: [root]))
        #expect(result.requests.count == 1)
        let row = try #require(result.requests.first)
        #expect(row.agent == .claudeCode && row.channelIdentity == "Claude")
        #expect(row.outputTokens == 150 && row.reasoningTokens == 45 && row.tps == 50)
        #expect(row.requestedServiceTier == "priority" && row.serviceTier == "default" && row.durationMS == 3000)
        let telemetryOnly = try #require(collector.scan(deviceID: testDevice, roots: only(.claudeCode, at: [otlp])).requests.first)
        #expect(telemetryOnly.requestedServiceTier == "priority" && telemetryOnly.serviceTier == nil)

        let desktop = try collector.scan(deviceID: testDevice, roots: only(.claudeDesktop, at: [log]))
        #expect(desktop.requests.first?.agent == .claudeDesktop)
        #expect(desktop.requests.first?.tps == nil)
        #expect(desktop.requests.first?.serviceTier == "default" && desktop.requests.first?.requestedServiceTier == nil)
    }
}

@Test func claudeRescanPublishesProvisionalIDRetirementWithAnObservedSuccessor() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("a.jsonl")
        let copy = root.appendingPathComponent("b.jsonl")
        let firstLine = """
        {"type":"assistant","sessionId":"live","timestamp":"2026-11-10T08:00:02Z","message":{"id":"message","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":20}}}
        """
        let resolvedLine = """
        {"type":"assistant","sessionId":"live","requestId":"request","timestamp":"2026-11-10T08:00:04Z","message":{"id":"message","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":200}}}
        """
        try firstLine.write(to: log, atomically: true, encoding: .utf8)
        let collector = UsageCollectors(), roots = only(.claudeCode, at: [root])
        let initial = try collector.scan(deviceID: testDevice, roots: roots)
        let provisional = try #require(initial.requests.first)
        #expect(initial.requests.count == 1 && initial.supersededRequestIDs.isEmpty)

        // Rotation can leave only the line carrying both identifiers on the
        // next scan; the earlier provisional record is already on disk.
        try resolvedLine.write(to: log, atomically: true, encoding: .utf8)
        let resolved = try collector.scan(deviceID: testDevice, roots: roots)
        #expect(resolved.supersededRequestIDs == [provisional.id])
        let canonical = try #require(resolved.requests.first)
        #expect(canonical.id == collectorID(Agent.claudeCode.rawValue, "live", "request", "request"))
        let surviving = (initial.requests + resolved.requests).filter { !resolved.supersededRequestIDs.contains($0.id) }
        #expect(surviving.count == 1 && surviving.first?.outputTokens == 200)

        // A copied archive may still present the provisional form by itself.
        try firstLine.write(to: copy, atomically: true, encoding: .utf8)
        let withCopy = try collector.scan(deviceID: testDevice, roots: roots)
        let noChanges = try collector.scan(deviceID: testDevice, roots: roots)
        #expect(withCopy.requests == resolved.requests && withCopy.supersededRequestIDs == resolved.supersededRequestIDs)
        #expect(noChanges.requests == withCopy.requests && noChanges.supersededRequestIDs == withCopy.supersededRequestIDs)
    }
}

@Test func claudeAliasPromotionRequiresUniqueClaimsAcrossAllFiles() throws {
    try collectorFixture { root in
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-11-10T08:00:02Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":20}}}
        """
        try line.write(to: root.appendingPathComponent("provisional.jsonl"), atomically: true, encoding: .utf8)
        for id in ["req-a", "req-b"] {
            let variant = line.replacingOccurrences(of: "\"sessionId\"", with: "\"requestId\":\"\(id)\",\"sessionId\"")
            try variant.write(to: root.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        let result = try UsageCollectors().scan(deviceID: testDevice, roots: only(.claudeCode, at: [root]))
        #expect(result.supersededRequestIDs.isEmpty)
        #expect(result.requests.count == 3)
    }
}

@Test func conflictingClaudeTierSurvivesRevisionsAndPortableRoundTrip() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("speed.jsonl")
        let early = """
        {"type":"assistant","sessionId":"s","requestId":"request","timestamp":"2026-11-10T08:00:02Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":20,"speed":"fast"}}}
        """
        let later = """
        {"type":"assistant","sessionId":"s","requestId":"request","timestamp":"2026-11-10T08:00:04Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":20,"speed":"standard"}}}
        """
        let collector = UsageCollectors(), roots = only(.claudeCode, at: [root])
        try early.write(to: log, atomically: true, encoding: .utf8)
        let fast = try #require(collector.scan(deviceID: testDevice, roots: roots).requests.first)
        #expect(fast.serviceTier == "priority" && fast.actualServiceTierEvidence == nil)

        try (early + "\n" + later).write(to: log, atomically: true, encoding: .utf8)
        let conflicted = try #require(collector.scan(deviceID: testDevice, roots: roots).requests.first)
        let decoded = try JSONDecoder().decode(UsageRequest.self, from: JSONEncoder().encode(conflicted))
        #expect(decoded.serviceTier == nil && decoded.actualServiceTierEvidence == .conflicting && decoded.isValid)
        #expect(decoded.preservingEvidence(from: fast).serviceTier == nil)

        // A less-informed duplicate with revised counters can't resurrect Fast.
        var laterFast = fast
        laterFast.outputTokens = 25
        let combined = laterFast.preservingEvidence(from: decoded)
        #expect(combined.outputTokens == 25 && combined.serviceTier == nil && combined.actualServiceTierEvidence == .conflicting)
    }
}

@Test func collectorDuplicateCountersDoNotYieldToMetadataOrIncomparableTotals() throws {
    try collectorFixture { root in
        let full = """
        {"type":"assistant","sessionId":"s","requestId":"request","timestamp":"2026-11-10T08:00:02Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":150}}}
        """
        let partialWithTiming = """
        {"type":"assistant","sessionId":"s","requestId":"request","requestDurationMs":3000,"timestamp":"2026-11-10T08:00:03Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":10,"speed":"fast"}}}
        """
        let crossed = """
        {"type":"assistant","sessionId":"s","requestId":"request","timestamp":"2026-11-10T08:00:04Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":300}}}
        """
        let incompatibleModel = """
        {"type":"assistant","sessionId":"s","requestId":"request","requestDurationMs":2000,"timestamp":"2026-11-10T08:00:05Z","message":{"id":"m","model":"claude-sonnet","usage":{"input_tokens":50,"output_tokens":150}}}
        """
        for (name, line) in [("a", full), ("b", partialWithTiming), ("c", crossed), ("d", incompatibleModel)] {
            try line.write(to: root.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
        }
        let result = try UsageCollectors().scan(deviceID: testDevice, roots: only(.claudeCode, at: [root]))
        let accepted = try #require(result.requests.first)
        #expect(result.requests.count == 1 && accepted.inputTokens == 50 && accepted.outputTokens == 150)
        #expect(accepted.modelIdentity == "claude-opus-5-5" && accepted.durationMS == nil && accepted.serviceTier == nil)
    }
}

@Test func codexEstimatesRespectToolAndTurnBoundaries() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("codex-estimate.jsonl")
        try """
        {"timestamp":"2026-11-10T08:00:00Z","type":"session_meta","payload":{"id":"session","model_provider":"openai"}}
        {"timestamp":"2026-11-10T08:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"first"}}
        {"timestamp":"2026-11-10T08:00:01Z","type":"turn_context","payload":{"turn_id":"first","model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-10T08:00:03Z","type":"response_item","payload":{"type":"function_call"}}
        {"timestamp":"2026-11-10T08:00:05Z","type":"response_item","payload":{"type":"function_call_output"}}
        {"timestamp":"2026-11-10T08:00:06Z","type":"token_usage_record","payload":{"response_id":"first","turn_id":"first","usage":{"input_tokens":100,"output_tokens":1200}}}
        {"timestamp":"2026-11-10T08:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":1200},"total_token_usage":{"input_tokens":100,"output_tokens":1200}}}}
        {"timestamp":"2026-11-10T08:00:08Z","type":"response_item","payload":{"type":"reasoning"}}
        {"timestamp":"2026-11-10T08:00:10Z","type":"token_usage_record","payload":{"response_id":"second","turn_id":"first","usage":{"input_tokens":200,"output_tokens":1500}}}
        {"timestamp":"2026-11-10T08:00:12Z","type":"token_usage_record","payload":{"response_id":"third","turn_id":"first","request_duration_ms":1000,"usage":{"input_tokens":300,"output_tokens":1300}}}
        {"timestamp":"2026-11-10T08:00:14Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"first","duration_ms":13000}}
        {"timestamp":"2026-11-10T08:03:00Z","type":"turn_context","payload":{"turn_id":"next","model":"gpt-6.1-sol"}}
        {"timestamp":"2026-11-10T08:03:01Z","type":"token_usage_record","payload":{"response_id":"next","turn_id":"next","usage":{"input_tokens":400,"output_tokens":1400}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let rows = try UsageCollectors().scan(deviceID: testDevice, roots: only(.codex, at: [log])).requests
        #expect(rows.count == 4)
        let first = try #require(rows.first { $0.outputTokens == 1200 })
        #expect(first.estimatedDurationMS == 2000 && first.estimatedTimingSource == "codex-session-log")
        #expect(first.tps == nil && first.estimatedTPS == 600)
        let second = try #require(rows.first { $0.outputTokens == 1500 })
        #expect(second.estimatedDurationMS == 5000 && second.estimatedTPS == 300)
        let exact = try #require(rows.first { $0.outputTokens == 1300 })
        #expect(exact.tps == 1300 && exact.estimatedTPS == nil && exact.estimatedDurationMS == nil)
        let otherTurn = try #require(rows.first { $0.outputTokens == 1400 })
        #expect(otherTurn.estimatedDurationMS == nil && otherTurn.durationMS == nil)
    }
}

@Test func claudeEstimatesUseAcceptedBlocksWithoutReplayingIdleTime() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("claude-estimate.jsonl")
        try """
        {"timestamp":"2026-11-10T08:00:00Z","type":"user","sessionId":"s","uuid":"user","message":{"role":"user"}}
        {"timestamp":"2026-11-10T08:00:02Z","type":"assistant","sessionId":"s","uuid":"a1","requestId":"req-a","message":{"id":"m-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1200}}}
        {"timestamp":"2026-11-10T08:00:05Z","type":"assistant","sessionId":"s","uuid":"a2","requestId":"req-a","message":{"id":"m-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1200}}}
        {"timestamp":"2026-11-10T08:00:07Z","type":"assistant","sessionId":"s","uuid":"a2","requestId":"req-a","message":{"id":"m-a","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1200}}}
        {"timestamp":"2026-11-10T08:00:08Z","type":"assistant","sessionId":"s","uuid":"b","parentUuid":"a2","requestId":"req-b","message":{"id":"m-b","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1500}}}
        {"timestamp":"2026-11-10T08:00:09Z","type":"system","subtype":"turn_duration","sessionId":"s","durationMs":9000}
        {"timestamp":"2026-11-10T08:00:12Z","type":"assistant","sessionId":"s","uuid":"c","parentUuid":"b","requestId":"req-c","message":{"id":"m-c","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1400}}}
        {"timestamp":"2026-11-10T08:00:13Z","type":"user","sessionId":"s","uuid":"tool","message":{"role":"user","content":[{"type":"tool_result"}]}}
        {"timestamp":"2026-11-10T08:00:15Z","type":"assistant","sessionId":"s","uuid":"d","requestId":"req-d","requestDurationMs":1000,"message":{"id":"m-d","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1300}}}
        """.write(to: log, atomically: true, encoding: .utf8)
        let rows = try UsageCollectors().scan(deviceID: testDevice, roots: only(.claudeCode, at: [log])).requests
        #expect(rows.count == 4)
        let first = try #require(rows.first { $0.outputTokens == 1200 })
        #expect(first.estimatedDurationMS == 5000 && first.estimatedTimingSource == "claude-session-log")
        #expect(first.estimatedTPS == 240 && first.tps == nil)
        let second = try #require(rows.first { $0.outputTokens == 1500 })
        #expect(second.estimatedDurationMS == 3000 && second.estimatedTPS == 500)
        let noBoundary = try #require(rows.first { $0.outputTokens == 1400 })
        #expect(noBoundary.estimatedDurationMS == nil)
        let exact = try #require(rows.first { $0.outputTokens == 1300 })
        #expect(exact.tps == 1300 && exact.estimatedTPS == nil && exact.estimatedDurationMS == nil)
    }
}

@Test func antigravityReadsOnlyRequestMetadataAndFoldsResponse() throws {
    try collectorFixture { root in
        let file = root.appendingPathComponent("33333333-3333-4333-8333-333333333333.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        // Fixture mirrors observed metadata fields (gen_metadata=1/19,
        // steps=1/1 and 9/{2,3,5,11}) without transcript text or account IDs.
        let sql = """
        CREATE TABLE gen_metadata(idx INTEGER, data BLOB);
        CREATE TABLE steps(idx INTEGER, metadata BLOB, step_payload BLOB);
        INSERT INTO gen_metadata VALUES (0, X'0A159A011267656D696E692D332E382D666C6173682D6E');
        INSERT INTO steps VALUES (1, X'0A0208014A0D1064181428325A056669787472', X'FFAABBCC');
        INSERT INTO steps VALUES (2, X'0A0208024A0D1064181E28325A056669787472', X'FFEEDDCC');
        """
        let outcome = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        #expect(outcome == SQLITE_OK)
        let result = try UsageCollectors().scan(deviceID: testDevice, roots: only(.antigravity, at: [file]))
        #expect(result.reports.first { $0.agent == .antigravity }?.files == 1)
        #expect(result.requests.count == 1)
        let row = try #require(result.requests.first)
        #expect(row.agent == .antigravity && row.requestedModel == "gemini-3.8-flash")
        #expect(row.sentModel == "gemini-3.8-flash-n" && row.outputTokens == 30 && row.cacheReadTokens == 50)
        #expect(row.tps == nil)
    }
}

@Test func collectorsAndLedgerOmitConversationText() throws {
    try collectorFixture { root in
        let log = root.appendingPathComponent("private-chat.jsonl")
        try """
        {"type":"custom-title","sessionId":"privacy-session","customTitle":"PRIVATE_CUSTOM_TITLE_EXAMPLE"}
        {"type":"ai-title","sessionId":"privacy-session","aiTitle":"PRIVATE_AI_TITLE_EXAMPLE"}
        {"type":"user","sessionId":"privacy-session","message":{"content":"PRIVATE_PROMPT_EXAMPLE"}}
        {"type":"assistant","sessionId":"privacy-session","requestId":"req_privacy","timestamp":"2026-11-10T08:00:02Z","message":{"id":"msg_privacy","model":"claude-opus-5-5","content":[{"type":"text","text":"PRIVATE_RESPONSE_EXAMPLE"},{"type":"tool_use","input":{"arg":"PRIVATE_TOOL_EXAMPLE"}}],"usage":{"input_tokens":20,"output_tokens":10}}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let collector = UsageCollectors()
        let result = try collector.scan(deviceID: testDevice, roots: only(.claudeCode, at: [log]))
        let row = try #require(result.requests.first)
        #expect(result.requests.count == 1)
        #expect(result.sessionTitles == [row.sessionKey: "PRIVATE_CUSTOM_TITLE_EXAMPLE"])
        let encoded = try JSONEncoder().encode(row)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(!serialized.contains("PRIVATE_") && !serialized.contains("sessionTitle"))

        // An older portable/WebDAV row may have carried title or an unknown
        // body key. Typed decoding never stores either for later export.
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old["sessionTitle"] = "PRIVATE_TITLE_EXAMPLE"
        old["body"] = "PRIVATE_BODY_EXAMPLE"
        let decoded = try JSONDecoder().decode(UsageRequest.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded == row)
        let rewritten = try JSONEncoder().encode(decoded)
        let clean = String(decoding: rewritten, as: UTF8.self)
        #expect(!clean.contains("PRIVATE_") && !clean.contains("sessionTitle"))

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let titleEvent = #"{"type":"custom-title","sessionId":"privacy-session","customTitle":"New native name"}"#
        try handle.write(contentsOf: Data(("\n" + titleEvent + "\n").utf8))
        try handle.close()
        let renamed = try collector.scan(deviceID: testDevice, roots: only(.claudeCode, at: [log]))
        #expect(renamed.requests == result.requests)
        #expect(renamed.sessionTitles[row.sessionKey] == "New native name")
    }
}

@Test func codexSessionTitlesFollowNativeIndexRenamesWithoutChangingUsage() throws {
    try collectorFixture { root in
        let nested = root.appendingPathComponent("sessions/2026/11/10", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        try """
        {"id":"named","thread_name":"Original Native Title","updated_at":"2026-11-10T08:00:01Z"}
        {"id":"unnamed","title":"Not an explicit name","first_user_message":"Private prompt"}
        """.write(to: index, atomically: true, encoding: .utf8)
        let rollout = nested.appendingPathComponent("rollout.jsonl")
        try """
        {"timestamp":"2026-11-10T08:00:00Z","type":"session_meta","payload":{"id":"named","model_provider":"openai"}}
        {"timestamp":"2026-11-10T08:00:03Z","type":"token_usage_record","payload":{"response_id":"response","model":"gpt-6.1-sol","usage":{"input_tokens":100,"output_tokens":1200}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)
        let collector = UsageCollectors()
        let roots = only(.codex, at: [rollout])
        let first = try collector.scan(deviceID: "My-Device", roots: roots)
        let row = try #require(first.requests.first)
        #expect(first.sessionTitles == [row.sessionKey: "Original Native Title"])
        let initial = try String(contentsOf: index, encoding: .utf8)
        try (initial + "\n" + """
        {"id":"named","thread_name":"Renamed in Codex","updated_at":"2026-11-10T08:01:00Z"}
        {"id":"named","thread_name":"Older Copy","updated_at":"2026-11-10T08:00:30Z"}
        """).write(to: index, atomically: true, encoding: .utf8)
        let renamed = try collector.scan(deviceID: "My-Device", roots: roots)
        #expect(renamed.requests == first.requests)
        #expect(renamed.sessionTitles == [row.sessionKey: "Renamed in Codex"])
        let disabled = try collector.scan(deviceID: "My-Device", roots: only(.codex, at: []))
        #expect(disabled.sessionTitles.isEmpty)
    }
}
