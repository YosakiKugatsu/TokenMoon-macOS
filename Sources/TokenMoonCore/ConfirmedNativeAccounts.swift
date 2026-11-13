// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Explicitly confirmed native request accounts, scoped to one owning device.
/// These mappings do not establish an authentication method or override
/// per-request evidence.
public struct ConfirmedNativeAccounts: Equatable, Sendable {
    private let ownerDeviceID: String
    private let codexEmail: String?
    private let claudeCodeEmail: String?

    public init?(ownerDeviceID: String, codexEmail: String? = nil, claudeCodeEmail: String? = nil) {
        guard let owner = UUID(uuidString: ownerDeviceID), owner.uuidString.lowercased() == ownerDeviceID.lowercased() else { return nil }
        let codex = codexEmail.flatMap(Self.normalizedEmail)
        let claude = claudeCodeEmail.flatMap(Self.normalizedEmail)
        guard codexEmail == nil || codex != nil, claudeCodeEmail == nil || claude != nil,
              codex != nil || claude != nil else { return nil }
        self.ownerDeviceID = owner.uuidString.lowercased()
        self.codexEmail = codex
        self.claudeCodeEmail = claude
    }

    public func applying(to request: UsageRequest) -> UsageRequest {
        guard request.account?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
              request.accountEvidence == nil, request.loginMethodEvidence != .conflicting,
              request.deviceID.lowercased() == ownerDeviceID,
              let email = confirmedEmail(for: request), !isExplicitAPIKeyLogin(request.loginMethod) else { return request }
        if let creator = request.sessionCreatorAccountEmail, Self.normalizedEmail(creator) != email {
            return request
        }
        var result = request
        result.account = email
        result.accountEvidence = .userConfirmed
        return result.isValid ? result : request
    }

    private func confirmedEmail(for request: UsageRequest) -> String? {
        switch (request.agent, request.source) {
        case (.codex, "codex.token_usage_record"), (.codex, "codex.token_count"), (.codex, "magpie-native-history"):
            codexEmail
        case (.claudeCode, "claude.assistant"), (.claudeCode, "magpie-native-history"):
            claudeCodeEmail
        default:
            nil
        }
    }

    private static func normalizedEmail(_ raw: String) -> String? {
        guard let email = creatorAccountEmail(raw)?.lowercased(),
              email.range(of: #"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+$"#,
                          options: .regularExpression) != nil else { return nil }
        return email
    }

}
