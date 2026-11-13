// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct CodexCreatorIdentity: Equatable, Hashable, Sendable {
    let userID: String
    let accountID: String

    init?(userID: String?, accountID: String?) {
        guard let userID = collectorText(userID, limit: 128),
              !userID.contains(where: \.isWhitespace),
              let accountID, let uuid = UUID(uuidString: accountID) else { return nil }
        self.userID = userID
        self.accountID = uuid.uuidString.lowercased()
    }
}

/// Observed Codex identities, held only in memory. A workspace can have multiple
/// users; neither its UUID nor the currently selected email is a sufficient key.
public struct CodexCreatorAccounts: Equatable, Sendable {
    private let emails: [CodexCreatorIdentity: String]

    public init() { emails = [:] }

    init(sessions: [CodexAccountSessionsReply.Session]) {
        var matches: [CodexCreatorIdentity: String] = [:]
        var conflicts: Set<CodexCreatorIdentity> = []
        for session in sessions {
            guard let email = creatorAccountEmail(session.email) else { continue }
            let workspaceIDs = session.workspaces.map { Optional($0.accountId) } + [session.selectedWorkspaceAccountId]
            for workspaceID in workspaceIDs {
                guard let identity = CodexCreatorIdentity(userID: session.userId, accountID: workspaceID),
                      !conflicts.contains(identity) else { continue }
                if let previous = matches[identity], previous.caseInsensitiveCompare(email) != .orderedSame {
                    matches.removeValue(forKey: identity)
                    conflicts.insert(identity)
                } else {
                    matches[identity] = matches[identity].map { min($0, email) } ?? email
                }
            }
        }
        emails = matches
    }

    func email(for identity: CodexCreatorIdentity) -> String? { emails[identity] }
}

struct CodexAccountSessionsReply: Decodable {
    struct Session: Decodable {
        struct Workspace: Decodable {
            let accountId: String
        }
        let userId: String?
        let email: String?
        let sessionId: String?
        let isActive: Bool?
        let selectedWorkspaceAccountId: String?
        let workspaces: [Workspace]

        init(userId: String?, email: String?, selectedWorkspaceAccountId: String?, workspaces: [Workspace],
             sessionId: String? = nil, isActive: Bool? = nil) {
            self.userId = userId
            self.email = email
            self.selectedWorkspaceAccountId = selectedWorkspaceAccountId
            self.workspaces = workspaces
            self.sessionId = sessionId
            self.isActive = isActive
        }
    }
    let sessions: [Session]
    let activeSessionId: String?

    var activeWorkspace: (email: String, accountID: String)? {
        guard let activeSessionId, !activeSessionId.isEmpty else { return nil }
        let matches = sessions.filter { $0.sessionId == activeSessionId }
        guard matches.count == 1, let active = matches.first, active.isActive == true,
              let email = creatorAccountEmail(active.email),
              let accountID = active.selectedWorkspaceAccountId, UUID(uuidString: accountID) != nil,
              active.workspaces.contains(where: { $0.accountId == accountID }) else { return nil }
        return (email, accountID)
    }

    func matchesActiveWorkspace(_ reportedAccountID: String?) -> Bool {
        guard let activeWorkspace, let reportedAccountID else { return false }
        return activeWorkspace.accountID == reportedAccountID
    }
}

func creatorAccountEmail(_ raw: String?) -> String? {
    guard let email = collectorText(raw, limit: 254),
          !email.contains(where: { $0.isWhitespace || $0 == "|" }) else { return nil }
    let components = email.split(separator: "@", omittingEmptySubsequences: false)
    guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }
    return email
}
