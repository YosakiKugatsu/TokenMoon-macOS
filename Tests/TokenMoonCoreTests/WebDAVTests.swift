// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import TokenMoonCore

final class WebDAVTests: XCTestCase, @unchecked Sendable {
    func testTwoDevicesMergeMonthlyHistoryAndRetryConflict() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TOKENMOON_TEST_DAV"], let url = URL(string: endpoint),
              url.scheme == "http", url.host == "127.0.0.1" else {
            throw XCTSkip("Run python3 scripts/verify-webdav.py to use the local WebDAV fixture.")
        }
        let configuration = WebDAVConfiguration(url: url, username: "tokenmoon", password: "test")
        let first = WebDAVClient(configuration: configuration)
        let second = WebDAVClient(configuration: configuration)
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "22222222-2222-4222-8222-222222222222"

        func make(_ id: String, _ device: String, _ time: TimeInterval) -> UsageRequest {
            UsageRequest(
                id: id, sessionID: "session", deviceID: device, agent: .codex, timestamp: Date(timeIntervalSince1970: time),
                requestedModel: "gpt-6.1-sol", status: "success", durationMS: 1000, timingSource: "test-full-request",
                inputTokens: 100, outputTokens: 20
            )
        }

        let monthBoundary: TimeInterval = 1_793_491_200 // 2026-11-01T00:00:00Z
        let october = make("october", a, monthBoundary - 0.0007)
        var november = make("november", a, monthBoundary + 0.9876)
        november.outputTokens = 1_600
        november.durationMS = nil
        november.timingSource = nil
        november.estimatedDurationMS = 2_000
        november.estimatedTimingSource = "codex-session-log"
        let peer = make("november", b, monthBoundary + 11)
        let original = try await first.sync(deviceID: a, deviceName: "Desk", requests: [october, november])
        XCTAssertEqual(Set(original.remoteRequests.map(\.key)), Set([october.key, november.key]))
        // A raw re-scan may omit timing that was previously recovered and synchronized.
        var partial = november
        partial.estimatedDurationMS = nil
        partial.estimatedTimingSource = nil
        let unchanged = try await first.sync(deviceID: a, deviceName: "Desk", requests: [october, partial])
        XCTAssertEqual(Set(unchanged.remoteRequests.map(\.key)), Set([october.key, november.key]))
        let estimate = try XCTUnwrap(unchanged.remoteRequests.first(where: { $0.key == november.key }))
        XCTAssertNil(estimate.tps)
        XCTAssertEqual(estimate.estimatedTPS, 800)
        XCTAssertEqual(estimate.estimatedTimingSource, "codex-session-log")

        let imported = try await second.sync(deviceID: b, deviceName: "Notebook", requests: [peer])
        XCTAssertEqual(imported.deviceNames, [a: "Desk", b: "Notebook"])
        XCTAssertEqual(Set(imported.remoteRequests.map(\.key)), Set([october.key, november.key, peer.key]))
        let downloaded = try XCTUnwrap(imported.remoteRequests.first(where: { $0.key == november.key }))
        XCTAssertEqual(downloaded.estimatedDurationMS, 2_000)
        XCTAssertEqual(downloaded.estimatedTimingSource, "codex-session-log")
        XCTAssertNil(downloaded.durationMS)
        XCTAssertNil(downloaded.tps)

        var updated = november
        updated.durationMS = 1_000
        updated.timingSource = "test-full-request"
        let merged = try await first.sync(deviceID: a, deviceName: "Desk", requests: [updated])
        XCTAssertEqual(merged.remoteRequests.count, 4)
        let upgraded = try XCTUnwrap(merged.remoteRequests.first(where: { $0.key == updated.key }))
        XCTAssertEqual(upgraded.tps, 1_600)
        XCTAssertEqual(upgraded.estimatedTPS, 800)
        XCTAssertEqual(merged.remoteRequests.first(where: { $0.id == "concurrent" })?.outputTokens, 10)

        let restored = try await first.sync(deviceID: a, deviceName: "Desk", requests: [])
        XCTAssertEqual(restored.remoteRequests.count, 4)
        XCTAssertEqual(restored.remoteRequests.first(where: { $0.key == october.key })?.outputTokens, 20)

        var cannotOverwrite = october
        cannotOverwrite.outputTokens = 99
        let protected = try await first.sync(deviceID: a, deviceName: "Desk", requests: [cannotOverwrite])
        let issue = try XCTUnwrap(protected.issues.first)
        XCTAssertEqual(issue.filename, "\(a)--2026-10.json")
        XCTAssertEqual(issue.operation, .publish)
        XCTAssertTrue(issue.retainedCachedData)
        XCTAssertEqual(protected.remoteRequests.first(where: { $0.key == october.key })?.outputTokens, 20)
    }

    func testPartialSyncKeepsValidatedCacheAndPublishesOwnedAliasRemoval() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TOKENMOON_TEST_DAV_RESILIENCE"],
              let url = URL(string: endpoint), url.scheme == "http", url.host == "127.0.0.1" else {
            throw XCTSkip("Run python3 scripts/verify-webdav.py to use the local WebDAV fixture.")
        }
        let configuration = WebDAVConfiguration(url: url, username: "tokenmoon", password: "test")
        let owner = WebDAVClient(configuration: configuration)
        let peer = WebDAVClient(configuration: configuration)
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "22222222-2222-4222-8222-222222222222"
        let november: TimeInterval = 1_793_491_200
        func make(_ id: String, _ device: String, _ time: TimeInterval, output: Int64) -> UsageRequest {
            .init(id: id, sessionID: "session", deviceID: device, agent: .claudeCode,
                  timestamp: Date(timeIntervalSince1970: time), requestedModel: "claude-opus",
                  status: "success", inputTokens: 50, outputTokens: output)
        }
        func changePhase(_ name: String) async throws {
            var request = URLRequest(url: url.appendingPathComponent("fixture-phase"))
            request.httpMethod = "POST"
            request.httpBody = Data(name.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        }

        let october = make("kept-october", a, november - 10, output: 10)
        let original = make("obsolete-id", a, november + 10, output: 20)
        let sameIDOnPeer = make(original.id, b, november + 11, output: 60)
        _ = try await owner.sync(deviceID: a, deviceName: "Desk", requests: [october, original])
        _ = try await peer.sync(deviceID: b, deviceName: "Notebook", requests: [sameIDOnPeer])
        let baseline = try await owner.sync(deviceID: a, deviceName: "Desk", requests: [])
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: cacheURL.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let handle = try FileHandle(forWritingTo: cacheURL)
        try baseline.cachedShards.writeJSON(to: handle)
        try handle.close()
        let data = try Data(contentsOf: cacheURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom {
            let text = try $0.singleValueContainer().decode(String.self)
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        }
        let persisted = try WebDAVShardCache.readJSON(data, range: 0..<data.count, decoder: decoder)
        let legacyReader = try decoder.decode(WebDAVShardCache.self, from: data)
        XCTAssertEqual(persisted.requests, legacyReader.requests)
        XCTAssertTrue(persisted.hasSameVersions(as: legacyReader))
        XCTAssertEqual(Set(persisted.requests.map(\.key)), Set([october.key, original.key, sameIDOnPeer.key]))

        try await changePhase("break")
        var attemptedUpdate = october
        attemptedUpdate.outputTokens = 99
        let replacement = make("canonical-id", a, november + 12, output: 200)
        let december = make("new-month", a, november + 31 * 86400, output: 30)
        let partial = try await owner.sync(
            deviceID: a, deviceName: "Desk", requests: [attemptedUpdate, original, replacement, december],
            cachedShards: persisted, supersededRequestIDs: [original.id]
        )
        XCTAssertEqual(partial.issues.map(\.filename), ["\(a)--2026-10.json", "\(b)--2026-11.json"])
        XCTAssertTrue(partial.issues.allSatisfy { $0.operation == .read && $0.retainedCachedData })
        XCTAssertEqual(Set(partial.remoteRequests.map(\.key)), Set([october.key, sameIDOnPeer.key, replacement.key, december.key]))
        XCTAssertEqual(partial.remoteRequests.first(where: { $0.key == october.key })?.outputTokens, 10)

        try await changePhase("restore")
        let recovered = try await owner.sync(
            deviceID: a, deviceName: "Desk", requests: [], cachedShards: partial.cachedShards, supersededRequestIDs: [original.id]
        )
        XCTAssertTrue(recovered.issues.isEmpty)
        XCTAssertEqual(Set(recovered.remoteRequests.map(\.key)), Set(partial.remoteRequests.map(\.key)))
        XCTAssertFalse(recovered.cachedShards.requests.contains { $0.key == original.key })

        try await changePhase("remove-peer")
        let withoutPeer = try await owner.sync(deviceID: a, deviceName: "Desk", requests: [], cachedShards: recovered.cachedShards)
        XCTAssertTrue(withoutPeer.issues.isEmpty)
        XCTAssertFalse(withoutPeer.cachedShards.requests.contains { $0.deviceID == b })
    }

    func testQuotaOnlyShardAndCPARequestMetadataSurviveBidirectionalSync() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TOKENMOON_TEST_DAV_QUOTA"],
              let url = URL(string: endpoint), url.scheme == "http", url.host == "127.0.0.1" else {
            throw XCTSkip("Run python3 scripts/verify-webdav.py to use the local WebDAV fixture.")
        }
        let configuration = WebDAVConfiguration(url: url, username: "tokenmoon", password: "test")
        let desktop = WebDAVClient(configuration: configuration)
        let gateway = WebDAVClient(configuration: configuration)
        let desk = "11111111-1111-4111-8111-111111111111"
        let gatewayID = "22222222-2222-4222-8222-222222222222"
        let november: TimeInterval = 1_793_491_200
        let october = Date(timeIntervalSince1970: november - 3_600 + 0.12345)
        let quota = QuotaWireObservation(
            agent: .codex, account: "fixture@example.invalid", windowID: "weekly", windowLabel: "Weekly",
            observedAt: october, usedPercent: 25, resetsAt: october.addingTimeInterval(2 * 86_400),
            durationSeconds: 7 * 86_400, plan: "Example plan"
        )
        let quotaOnly = try await desktop.sync(deviceID: desk, deviceName: "Desk", requests: [], quotaObservations: [quota])
        XCTAssertTrue(quotaOnly.issues.isEmpty)
        XCTAssertTrue(quotaOnly.remoteRequests.isEmpty)
        XCTAssertEqual(quotaOnly.quotaObservations.count, 1)

        let api = UsageRequest(
            id: "cpa-event", sessionID: "cpa-session", deviceID: gatewayID, agent: .cpa,
            timestamp: Date(timeIntervalSince1970: november + 10), requestedModel: "example-model",
            account: "sk-abcd***fg", status: "success", durationMS: 750, timingSource: "cpa", outputTokens: 40,
            sentServiceTier: "priority", cpaKeyID: "opaque-key-id", cpaKeyLabel: "Team", ttftMS: 70
        )
        let fromCPA = try await gateway.sync(deviceID: gatewayID, deviceName: "Example Gateway", requests: [api])
        XCTAssertTrue(fromCPA.issues.isEmpty)
        XCTAssertEqual(fromCPA.deviceNames[desk], "Desk")
        XCTAssertEqual(fromCPA.quotaObservations.map(\.windowLabel), ["Weekly"])
        let fromCache = try JSONDecoder().decode(WebDAVShardCache.self, from: JSONEncoder().encode(fromCPA.cachedShards))
        XCTAssertEqual(fromCache.quotaObservations, fromCPA.quotaObservations)

        let desktopRequest = UsageRequest(id: "desktop-event", sessionID: "session", deviceID: desk, agent: .codex,
                                          timestamp: october, requestedModel: "example-model", status: "success")
        let merged = try await desktop.sync(
            deviceID: desk, deviceName: "Desk", requests: [desktopRequest], cachedShards: quotaOnly.cachedShards
        )
        XCTAssertTrue(merged.issues.isEmpty)
        XCTAssertEqual(merged.quotaObservations.map(\.usedPercent), [25])
        let downloaded = try XCTUnwrap(merged.remoteRequests.first { $0.deviceID == gatewayID })
        XCTAssertEqual(downloaded.agent, .cpa)
        XCTAssertEqual(downloaded.cpaKeyID, "opaque-key-id")
        XCTAssertEqual(downloaded.cpaKeyLabel, "Team")
        XCTAssertEqual(downloaded.ttftMS, 70)
        XCTAssertEqual(downloaded.sentServiceTier, "priority")

        let unchanged = try await desktop.sync(
            deviceID: desk, deviceName: "Desk", requests: [desktopRequest], cachedShards: merged.cachedShards,
            quotaObservations: [quota]
        )
        XCTAssertTrue(unchanged.issues.isEmpty)
        XCTAssertEqual(unchanged.quotaObservations, merged.quotaObservations)
    }
}
