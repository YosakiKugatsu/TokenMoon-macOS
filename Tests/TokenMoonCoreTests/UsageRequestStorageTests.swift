// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

@Test func compactRequestsKeepLegacyWireShapeAndCopyOnWrite() throws {
    let bytes = Data("""
        {"id":"request","sessionID":"shared-session-identifier","deviceID":"shared-device-identifier",
         "agent":"codex","timestamp":100,"requestedModel":"gpt-6.1-sol","account":"person@example.test",
         "status":"success","inputTokens":12,"outputTokens":34,"cacheReadTokens":56,"cacheWriteTokens":0}
        """.utf8)
    let decoder = JSONDecoder()
    decoder.userInfo[UsageStringInterner.key] = UsageStringInterner()
    let original = try decoder.decode(UsageRequest.self, from: bytes)
    var enriched = original
    enriched.account = "other@example.test"
    enriched.outputTokens += 1
    #expect(original.account == "person@example.test")
    #expect(original.outputTokens == 34)
    #expect(enriched.account == "other@example.test")
    #expect(enriched.outputTokens == 35)
    let encoded = try JSONEncoder().encode(original)
    let roundTrip = try decoder.decode(UsageRequest.self, from: encoded)
    #expect(roundTrip == original)
    let legacy = try #require(try JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
    let current = try #require(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
    #expect(legacy == current)
}
