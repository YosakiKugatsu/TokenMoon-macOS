// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import Security

/// Reads the currently signed-in ChatGPT account through the installed Codex
/// client's official, read-only App Server methods. TokenMoon never reads the
/// client's credentials or starts a conversation.
public enum CodexQuotaReader {
    public static func read() async throws -> [QuotaAccount] {
        try await readWithCreatorAccounts().accounts
    }

    public struct Reading: Sendable {
        public let accounts: [QuotaAccount]
        /// A nil result means this native client did not return its session identities.
        public let creatorAccounts: CodexCreatorAccounts?
        /// Set only when the official client identified the active workspace for an unavailable reading.
        public let lastKnownAccountID: String?
    }

    public static func readWithCreatorAccounts() async throws -> Reading {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try readSynchronously() })
            }
        }
    }

    private static func readSynchronously() throws -> Reading {
        guard let executable = try officialExecutable() else {
            return Reading(accounts: [], creatorAccounts: nil, lastKnownAccountID: nil)
        }
        let connection = try CodexQuotaConnection(executable: executable)
        defer { connection.close() }

        let _: CodexQuotaEmpty = try connection.request(
            "initialize", id: 1,
            params: [
                "clientInfo": ["name": "tokenmoon", "title": "TokenMoon", "version": "1.0"],
                "capabilities": ["experimentalApi": true],
            ]
        )
        try connection.notifyInitialized()
        // The current client can identify its active sign-in locally. Try the
        // quota request before making any separate online workspace discovery.
        let sessions: CodexAccountSessionsReply? = try? connection.request(
            "accountSession/list", id: 4, params: ["refreshWorkspaceMetadata": false], timeout: 5
        )
        let creators = sessions.map { CodexCreatorAccounts(sessions: $0.sessions) }
        if let active = sessions?.activeWorkspace {
            let (limits, failureNote) = readLimits(connection)
            if sessions?.matchesActiveWorkspace(limits?.accountId) == true {
                let account = CodexQuotaAccountReply.Account(
                    type: "chatgpt", email: active.email, planType: limits?.mainPlanType, workspaceName: nil
                )
                let reading = makeAccount(account, limits: limits)
                return Reading(accounts: [reading], creatorAccounts: creators,
                               lastKnownAccountID: reading.windows.isEmpty ? reading.id : nil)
            }
            // A failure can recover history for the verified sign-in only. If
            // the client explicitly reports sign-out or non-ChatGPT auth, hide it.
            let reply: CodexQuotaAccountReply? = try? connection.request(
                "account/read", id: 2, params: ["refreshToken": false]
            )
            if let reply, reply.account?.type != "chatgpt" {
                return Reading(accounts: [], creatorAccounts: creators, lastKnownAccountID: nil)
            }
            let note = failureNote ?? "官方额度未能匹配当前 Codex 工作区"
            if let account = reply?.account,
               account.email?.quotaLabel?.caseInsensitiveCompare(active.email) != .orderedSame
                 || reply?.workspaceRouting?.chatgptAccountId.map({ $0 != active.accountID }) == true {
                let reading = makeAccount(account, limits: nil, failureNote: note)
                return Reading(accounts: [reading], creatorAccounts: creators, lastKnownAccountID: nil)
            }
            let account = reply?.account ?? CodexQuotaAccountReply.Account(
                type: "chatgpt", email: active.email, planType: nil, workspaceName: nil
            )
            let reading = makeAccount(account, limits: nil, failureNote: note, fallbackWorkspace: active.accountID)
            return Reading(accounts: [reading], creatorAccounts: creators,
                           lastKnownAccountID: reading.id)
        }
        // Older clients may not expose active sessions. Verify the auth type before fetching.
        let reply: CodexQuotaAccountReply = try connection.request(
            "account/read", id: 2, params: ["refreshToken": false]
        )
        guard let account = reply.account, account.type == "chatgpt" else {
            return Reading(accounts: [], creatorAccounts: creators, lastKnownAccountID: nil)
        }
        let (limits, failureNote) = readLimits(connection)
        let reading = makeAccount(account, limits: limits, failureNote: failureNote)
        return Reading(accounts: [reading], creatorAccounts: creators, lastKnownAccountID: nil)
    }

    private static func readLimits(_ connection: CodexQuotaConnection) -> (CodexQuotaLimitsReply?, String?) {
        do {
            let limits: CodexQuotaLimitsReply = try connection.request(
                "account/rateLimits/read", id: 3, timeout: 30
            )
            return (limits, nil)
        } catch CodexQuotaError.timedOut {
            return (nil, "读取官方额度超时，请稍后刷新")
        } catch {
            return (nil, "本次未能读取官方额度，请稍后刷新")
        }
    }

    private static func makeAccount(
        _ account: CodexQuotaAccountReply.Account, limits: CodexQuotaLimitsReply?, failureNote: String? = nil,
        fallbackWorkspace: String? = nil
    ) -> QuotaAccount {
        var buckets = limits?.rateLimitsByLimitId?.map { ($0.key, $0.value) } ?? []
        if buckets.isEmpty, let primary = limits?.rateLimits {
            buckets = [(primary.limitId ?? "codex", primary)]
        }
        buckets.sort { lhs, rhs in
            if (lhs.0 == "codex") != (rhs.0 == "codex") { return lhs.0 == "codex" }
            return lhs.0 < rhs.0
        }
        let windows = buckets.flatMap { key, bucket -> [QuotaWindow] in
            let id = key.quotaLabel ?? bucket.limitId?.quotaLabel ?? "codex"
            let prefix = id == "codex" ? "" : (bucket.limitName?.quotaLabel ?? id) + " · "
            return [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, raw in
                guard let raw, let used = raw.usedPercent, used.isFinite, used >= 0 else { return nil }
                let minutes = raw.windowDurationMins.flatMap { $0 > 0 ? $0 : nil }
                let reset = raw.resetsAt.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                return QuotaWindow(
                    id: "\(id):\(slot):\(minutes ?? 0)", label: prefix + windowLabel(minutes, slot: slot),
                    usedPercent: min(used, 100), resetsAt: reset,
                    durationSeconds: minutes.map { Double($0) * 60 }
                )
            }
        }
        let email = account.email?.quotaLabel
        let workspace = limits?.accountId ?? (windows.isEmpty ? fallbackWorkspace : nil) ?? account.workspaceName ?? ""
        let identity = [workspace, email?.lowercased() ?? ""].joined(separator: "\u{001F}")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return QuotaAccount(
            id: "codex:\(key)", agent: .codex, displayName: email ?? account.workspaceName?.quotaLabel ?? "ChatGPT 账号",
            plan: account.planType?.quotaLabel, windows: windows,
            note: windows.isEmpty ? (failureNote ?? "官方客户端暂未返回额度窗口") : nil, accountEmail: email
        )
    }

    private static func windowLabel(_ minutes: Int?, slot: String) -> String {
        guard let minutes else { return slot == "primary" ? "主要额度" : "次要额度" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440) 天" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    private static func officialExecutable() throws -> URL? {
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let appDirectories = [URL(fileURLWithPath: "/Applications", isDirectory: true), userApps]
        let bundles = ["ChatGPT.app", "Codex.app"]
        let resources = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex"
        ]
        let candidates = appDirectories.flatMap { directory in
            bundles.flatMap { bundle in resources.map { directory.appendingPathComponent(bundle).appendingPathComponent($0) } }
        } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .map { URL(fileURLWithPath: $0) }
        var found = false
        var requirement: SecRequirement?
        let expression = #"anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2" and identifier "codex""#
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw CodexQuotaError.untrustedClient }
        for candidate in candidates {
            let path = candidate.resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: path.path) else { continue }
            found = true
            var code: SecStaticCode?
            if SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
               SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
                return path
            }
        }
        if found { throw CodexQuotaError.untrustedClient }
        return nil
    }
}

private extension String {
    var quotaLabel: String? {
        let label = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 240,
              label.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return label
    }
}

private struct CodexQuotaEmpty: Decodable {}

private struct CodexQuotaAccountReply: Decodable {
    struct Account: Decodable {
        let type: String
        let email: String?
        let planType: String?
        let workspaceName: String?
    }
    struct WorkspaceRouting: Decodable {
        let chatgptAccountId: String?
    }
    let account: Account?
    let workspaceRouting: WorkspaceRouting?
}

private struct CodexQuotaLimitsReply: Decodable {
    struct Bucket: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let resetsAt: Double?
            let windowDurationMins: Int?
        }
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
    }
    let accountId: String?
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?

    var mainPlanType: String? { rateLimitsByLimitId?["codex"]?.planType ?? rateLimits?.planType }
}

private enum CodexQuotaError: LocalizedError {
    case untrustedClient, launchFailed, responseFailed, timedOut
    var errorDescription: String? {
        switch self {
        case .untrustedClient: "找不到签名有效的官方 Codex 客户端。"
        case .launchFailed: "无法启动 Codex 额度读取。"
        case .responseFailed: "Codex 客户端未能返回账号或额度信息。"
        case .timedOut: "Codex 额度读取超时。"
        }
    }
}

private final class CodexQuotaConnection {
    private struct Reply<Payload: Decodable>: Decodable {
        let id: Int?
        let result: Payload?
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let decoder = JSONDecoder()
    private var buffer = Data()
    private var received = 0

    init(executable: URL) throws {
        let inherited = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        // Match a caller's explicitly selected local Codex home, without passing
        // through API keys, auth overrides, proxy variables, or provider URLs.
        if let codexHome = inherited["CODEX_HOME"], codexHome.hasPrefix("/") {
            environment["CODEX_HOME"] = codexHome
        }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://",
                             "-c", #"chatgpt_base_url="https://chatgpt.com/backend-api/""#]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CodexQuotaError.launchFailed
        }
        // A child can exit between isRunning and a write. Treat that as a
        // request error rather than allowing SIGPIPE to affect the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func request<Payload: Decodable>(
        _ method: String, id: Int, params: [String: Any]? = nil, timeout: TimeInterval = 15
    ) throws -> Payload {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var message: [String: Any] = ["method": method, "id": id]
        if let params { message["params"] = params }
        try send(message)
        while true {
            let reply = try readLine(deadline: deadline)
            // Unknown notifications and other IDs never reach the UI or logs.
            guard let envelope = try? decoder.decode(Reply<Payload>.self, from: reply), envelope.id == id else {
                if let identity = try? decoder.decode(Reply<CodexQuotaEmpty>.self, from: reply), identity.id == id {
                    throw CodexQuotaError.responseFailed
                }
                continue
            }
            guard let result = envelope.result else { throw CodexQuotaError.responseFailed }
            return result
        }
    }

    func notifyInitialized() throws {
        try send(["method": "initialized"])
    }

    private func send(_ message: [String: Any]) throws {
        guard process.isRunning else { throw CodexQuotaError.responseFailed }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexQuotaError.responseFailed
        }
    }

    private func readLine(deadline: TimeInterval) throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexQuotaError.timedOut }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let state = poll(&event, 1, Int32(ceil(remaining * 1_000)))
            if state < 0 && errno == EINTR { continue }
            if state == 0 { throw CodexQuotaError.timedOut }
            guard state > 0 else { throw CodexQuotaError.responseFailed }
            var chunk = [UInt8](repeating: 0, count: 8_192)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexQuotaError.responseFailed }
            received += count
            guard received <= 1_048_576 else { throw CodexQuotaError.responseFailed }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        // End only this short-lived child. The official GUI process is untouched.
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }
}
