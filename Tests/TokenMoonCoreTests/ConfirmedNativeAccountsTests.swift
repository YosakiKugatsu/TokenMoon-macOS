// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import TokenMoonCore

struct ConfirmedNativeAccountsTests {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let codex = "codex@example.test"
    private let claude = "claude@example.test"

    private func row(_ agent: Agent = .codex, _ source: String = "codex.token_usage_record") -> UsageRequest {
        UsageRequest(id: "row", sessionID: "native-session", deviceID: owner, agent: agent,
                     timestamp: Date(timeIntervalSince1970: 1_795_000_000), requestedModel: "test-model",
                     inputTokens: 50, outputTokens: 100, source: source)
    }

    @Test func confirmsNewNativeRowsWithoutInventingAuthentication() throws {
        let policy = try #require(ConfirmedNativeAccounts(ownerDeviceID: owner, codexEmail: codex.uppercased(),
                                                          claudeCodeEmail: claude))
        var traced = row()
        traced.loginMethod = "chatgpt"
        traced.loginMethodEvidence = .turnTrace
        traced.sessionCreatorAccountID = peer
        traced.sessionCreatorAccountEmail = codex
        for (original, expected) in [(row(), codex), (traced, codex), (row(.codex, "codex.token_count"), codex),
                                     (row(.codex, "magpie-native-history"), codex),
                                     (row(.claudeCode, "claude.assistant"), claude),
                                     (row(.claudeCode, "magpie-native-history"), claude)] {
            var confirmed = original
            confirmed.account = expected
            confirmed.accountEvidence = .userConfirmed
            let result = policy.applying(to: original)
            #expect(result == confirmed && result.isValid)
            #expect(policy.applying(to: result) == result)
        }
    }

    @Test func preservesRequestEvidenceAndDeviceBoundaries() throws {
        let policy = try #require(ConfirmedNativeAccounts(ownerDeviceID: owner, codexEmail: codex, claudeCodeEmail: claude))
        var observed = row()
        observed.account = "observed@example.test"
        var key = row(.claudeCode, "claude.assistant")
        key.loginMethod = "API key"
        var conflictingTrace = row()
        conflictingTrace.loginMethodEvidence = .conflicting
        var conflictingCreator = row()
        conflictingCreator.sessionCreatorAccountID = peer
        conflictingCreator.sessionCreatorAccountEmail = "other@example.test"
        var remote = row()
        remote.deviceID = peer
        for original in [observed, key, conflictingTrace, conflictingCreator, remote,
                         row(.cpa, "codex.token_usage_record"), row(.claudeDesktop, "claude.assistant"),
                         row(.codex, "cpa-gateway"), row(.claudeCode, "codex.token_usage_record")] {
            #expect(policy.applying(to: original) == original)
        }
    }

    @Test func rejectsInvalidConfigurationAndLeavesUnmappedAgentAlone() throws {
        #expect(ConfirmedNativeAccounts(ownerDeviceID: "not-a-device", codexEmail: codex) == nil)
        #expect(ConfirmedNativeAccounts(ownerDeviceID: owner, claudeCodeEmail: "not-an-email") == nil)
        #expect(ConfirmedNativeAccounts(ownerDeviceID: owner) == nil)
        let codexOnly = try #require(ConfirmedNativeAccounts(ownerDeviceID: owner, codexEmail: codex))
        let request = row(.claudeCode, "claude.assistant")
        #expect(codexOnly.applying(to: request) == request)
    }

    @Test func laterExplicitAPIKeyEvidenceClearsEarlierConfirmedSubscriptionAccount() throws {
        let policy = try #require(ConfirmedNativeAccounts(ownerDeviceID: owner, claudeCodeEmail: claude))
        let request = row(.claudeCode, "claude.assistant")
        let prior = policy.applying(to: request)
        #expect(prior.account == claude)

        var observed = request
        observed.loginMethod = "API Key"
        let result = observed.preservingEvidence(from: prior)
        #expect(result.loginMethod == "API Key")
        #expect(result.account == nil && result.accountEvidence == nil)
        #expect(policy.applying(to: result) == result)
    }
}
