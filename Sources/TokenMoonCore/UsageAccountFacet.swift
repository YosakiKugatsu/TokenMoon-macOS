// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A request account, separate from the session creator and inbound CPA key.
public enum UsageAccountFacet: Hashable, Sendable {
    case email(String)
    case apiKey(String?)
    case unattributed

    public var isAPIKey: Bool {
        if case .apiKey = self { return true }
        return false
    }

    public var id: String {
        switch self {
        case .email(let email): "email:" + email
        case .apiKey(let mask): "key:" + (mask ?? "")
        case .unattributed: "unattributed"
        }
    }

    public init?(id: String) {
        if id == "unattributed" { self = .unattributed }
        else if id.hasPrefix("email:") {
            guard let email = Self.email(String(id.dropFirst(6))) else { return nil }
            self = .email(email)
        } else if id.hasPrefix("key:") {
            let mask = String(id.dropFirst(4))
            guard mask.isEmpty || Self.matches(Self.maskPattern, mask) else { return nil }
            self = .apiKey(mask.isEmpty ? nil : mask)
        } else { return nil }
    }

    public var label: String {
        switch self {
        case .email(let email):
            let parts = email.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { return "账号未记录" }
            let local = parts[0]
            let count = local.count > 5 ? 2 : local.count > 2 ? 1 : 0
            return String(local.prefix(count)) + "***" + String(local.suffix(count)) + "@" + parts[1]
        case .apiKey(let mask):
            return mask.map { "API Key · " + $0 } ?? "API Key · 账号未记录"
        case .unattributed:
            return "账号未记录"
        }
    }

    private static let emailPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    private static let maskPattern = try! NSRegularExpression(pattern: #"(?i)sk-[A-Za-z0-9_-]{1,32}(?:\*{3,}|•{3,}|…+)[A-Za-z0-9_-]{1,12}"#)

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }

    private static func email(_ value: String) -> String? {
        guard value.utf8.count <= 254, value.contains("@"), matches(emailPattern, value) else { return nil }
        return value.lowercased()
    }

    /// Keep regex validation proportional to the number of identities, not requests.
    public struct Resolver {
        private var byAccount: [String: UsageAccountFacet] = [:]
        private var apiMethods: [String: Bool] = [:]

        public init() {}

        public mutating func includes(_ row: UsageRequest, selected: Set<UsageAccountFacet>,
                                      excludesAPIKeys: Bool) -> Bool {
            guard excludesAPIKeys || !selected.isEmpty else { return true }
            let account = resolve(row)
            return (!excludesAPIKeys || !account.isAPIKey) && (selected.isEmpty || selected.contains(account))
        }

        public mutating func resolve(_ row: UsageRequest) -> UsageAccountFacet {
            guard row.loginMethodEvidence != .conflicting else { return .unattributed }
            let explicitKey: Bool
            if let method = row.loginMethod {
                if let cached = apiMethods[method] {
                    explicitKey = cached
                } else {
                    explicitKey = isExplicitAPIKeyLogin(method)
                    apiMethods[method] = explicitKey
                }
            } else { explicitKey = false }
            let identity: UsageAccountFacet
            if let account = row.account {
                if let cached = byAccount[account] {
                    identity = cached
                } else {
                    let value = account.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let email = UsageAccountFacet.email(value) {
                        identity = .email(email)
                    } else if value.utf8.count <= 96, UsageAccountFacet.matches(UsageAccountFacet.maskPattern, value) {
                        identity = .apiKey(value)
                    } else {
                        identity = .unattributed
                    }
                    byAccount[account] = identity
                }
            } else { identity = .unattributed }
            if identity.isAPIKey { return identity }
            if explicitKey { return .apiKey(nil) }
            return identity
        }
    }
}
