// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Credential-free, account-attributed quota sample in a TokenMoon v1 monthly shard.
public struct QuotaWireObservation: Codable, Equatable, Sendable {
    public let agent: Agent
    public let account: String
    public let windowID: String
    public let windowLabel: String
    public let observedAt: Date
    public let usedPercent: Double
    public let resetsAt: Date?
    public let durationSeconds: Double?
    public let plan: String?

    public init(
        agent: Agent, account: String, windowID: String, windowLabel: String,
        observedAt: Date, usedPercent: Double, resetsAt: Date? = nil,
        durationSeconds: Double? = nil, plan: String? = nil
    ) {
        self.agent = agent
        self.account = account
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.observedAt = observedAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
        self.plan = plan
    }

    var isValid: Bool {
        Self.validText(account) && Self.validText(windowID) && Self.validText(windowLabel)
            && (plan.map(Self.validText) ?? true)
            && observedAt.timeIntervalSinceReferenceDate.isFinite
            && (resetsAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && (0...100).contains(usedPercent)
            && (durationSeconds.map { $0 > 0 && $0 <= 1e15 } ?? true)
            && account.range(of: #"(?i)^(?:bearer\s+\S+|sk-[a-z0-9_-]{8,}|sess-[a-z0-9_-]{8,}|eyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+|AIza[a-z0-9_-]{30,})$"#,
                             options: .regularExpression) == nil
    }

    private static func validText(_ value: String) -> Bool {
        value.utf16.count <= 512 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}
