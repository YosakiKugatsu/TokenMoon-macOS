// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

public enum OtherQuotaReader {
    public static func read() async -> [QuotaAccount] {
        async let claude = Task.detached(priority: .utility) { ClaudeQuota.read() }.value
        async let antigravity = AntigravityQuota.read()
        return await claude + antigravity
    }
}

enum ClaudeQuota {
    private struct AuthStatus: Decodable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
        let email: String?
        let orgId: String?
        let subscriptionType: String?
    }

    private struct UsageResponse: Decodable {
        let result: String?
        let localCommand: String?
        let isError: Bool?
        let numTurns: Int?
        let durationApiMs: Double?
        let totalCostUsd: Double?

        var isNativeUsage: Bool {
            localCommand == "usage" && numTurns == 0 && durationApiMs == 0 && totalCostUsd == 0
        }
    }

    private static let slashArguments = [
        "-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config",
        "--setting-sources", "", "--settings", #"{"disableDeepLinkRegistration":"disable"}"#,
        "--no-chrome", "--model", "tokenmoon-quota-no-inference",
    ]

    static func read() -> [QuotaAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let executable = executable(in: home) else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmoon-quota-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let environment = QuotaSubprocess.clientEnvironment
        guard let account = auth(executable: executable, directory: directory, environment: environment) else { return [] }
        let email = account.email.flatMap(cleanQuotaIdentity)
        let name = email ?? "Claude Code"
        let plan = account.subscriptionType.flatMap(cleanQuotaIdentity)
        let id = quotaOpaqueIdentity(prefix: "claude", components: [
            account.orgId ?? "", account.email?.lowercased() ?? "",
        ])
        let shared = sharesDesktopAccount(home: home, email: email)
            ? "与 Claude Desktop 最近记录的同一账号共用额度"
            : nil

        // A compatibility probe uses a deliberately unreachable origin. An
        // older CLI must demonstrate that /usage is a local, zero-turn command
        // before we allow it to refresh the native subscription snapshot.
        var probeEnvironment = environment.filter { !$0.key.lowercased().contains("proxy") }
        probeEnvironment["ANTHROPIC_BASE_URL"] = "https://tokenmoon.invalid:1"
        probeEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        let knownCommand = usage(
            executable: executable, directory: directory, environment: probeEnvironment, timeout: 4
        )?.isNativeUsage == true
        guard knownCommand else {
            return [QuotaAccount(id: id, agent: .claudeCode, displayName: name, plan: plan, windows: [],
                                 note: sharedNote(shared, "当前 Claude Code 版本未提供可验证的原生额度读取"),
                                 accountEmail: email)]
        }

        let result = usage(executable: executable, directory: directory, environment: environment, timeout: 12)
        // Do not attach a reading to a previously logged-in account if a
        // concurrent sign-out or account switch took place during refresh.
        guard let current = auth(executable: executable, directory: directory, environment: environment),
              account.email?.lowercased() == current.email?.lowercased(), account.orgId == current.orgId else { return [] }
        let now = Date()
        let windows: [QuotaWindow]
        if let result, result.isNativeUsage, result.isError == false, let text = result.result {
            windows = parseUsage(text, now: now)
        } else {
            windows = []
        }
        let failure = windows.isEmpty ? "官方客户端暂未返回可用的额度数据" : nil
        let isCached = environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] != nil && !windows.isEmpty
        let offline = isCached ? "读取的是官方客户端缓存；客户端已关闭后台查询" : nil
        return [QuotaAccount(id: id, agent: .claudeCode, displayName: name, plan: plan,
                             windows: windows, observedAt: isCached || windows.isEmpty ? nil : now,
                             note: sharedNote(shared, failure ?? offline), accountEmail: email,
                             provenance: isCached ? .cached : .live)]
    }

    private static func executable(in home: URL) -> URL? {
        [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath()
    }

    private static func auth(
        executable: URL, directory: URL, environment: [String: String]
    ) -> AuthStatus? {
        guard let data = QuotaSubprocess.read(executable, args: ["auth", "status", "--json"], directory: directory,
                                              environment: environment, timeout: 4),
              let account = try? JSONDecoder().decode(AuthStatus.self, from: data), account.loggedIn,
              account.authMethod?.lowercased() == "claude.ai", account.apiProvider?.lowercased() == "firstparty",
              account.subscriptionType?.lowercased() != "free",
              account.email.flatMap(cleanQuotaIdentity) != nil || account.orgId.flatMap(cleanQuotaIdentity) != nil
        else { return nil }
        return account
    }

    private static func usage(executable: URL, directory: URL, environment: [String: String], timeout: Double) -> UsageResponse? {
        guard let data = QuotaSubprocess.read(executable, args: slashArguments, directory: directory,
                                              environment: environment, timeout: timeout) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(UsageResponse.self, from: data)
    }

    private static func sharesDesktopAccount(home: URL, email: String?) -> Bool {
        guard let email, let desktop = Bundle(url: URL(fileURLWithPath: "/Applications/Claude.app")),
              desktop.bundleIdentifier == "com.anthropic.claudefordesktop",
              let desktopState = quotaLocalJSON(home.appendingPathComponent("Library/Application Support/Claude/config.json")),
              desktopState["oauth:staleSessionLatch"] == nil,
              let desktopID = desktopState["lastKnownAccountUuid"] as? String, UUID(uuidString: desktopID) != nil
        else { return false }
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        let stateURL = config?.appendingPathComponent(".claude.json") ?? home.appendingPathComponent(".claude.json")
        guard let state = quotaLocalJSON(stateURL), let account = state["oauthAccount"] as? [String: Any],
              let codeID = account["accountUuid"] as? String,
              let cachedEmail = account["emailAddress"] as? String else { return false }
        return codeID.caseInsensitiveCompare(desktopID) == .orderedSame && cachedEmail.caseInsensitiveCompare(email) == .orderedSame
    }

    private static func sharedNote(_ first: String?, _ second: String?) -> String? {
        let notes = [first, second].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    static func parseUsage(_ text: String, now: Date) -> [QuotaWindow] {
        let visible = text.replacingOccurrences(of: "\\u001B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let pattern = #"^Current (session|week(?: \(([^)]+)\))?):\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets (.+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        var seen = Set<String>()
        return visible.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            func capture(_ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            guard let rawPercent = capture(3), let percent = Double(rawPercent), percent.isFinite,
                  (0...100).contains(percent) else { return nil }
            let isSession = capture(1)?.lowercased() == "session"
            let span = isSession ? 5.0 * 3600 : 7.0 * 86400
            var scope = capture(2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if scope.lowercased().hasSuffix(" only") { scope = String(scope.dropLast(5)) }
            if scope.lowercased() == "all models" { scope = "" }
            let id = isSession ? "session" : scope.isEmpty ? "week" : "week:\(scope.lowercased())"
            let label = isSession ? "5 小时" : scope.isEmpty ? "7 天" : "7 天 · \(scope)"
            guard seen.insert(id).inserted else { return nil }
            let reset = capture(4).flatMap { parseReset($0, now: now, span: span) }
            if let reset, reset <= now { return nil }
            return QuotaWindow(id: id, label: label, usedPercent: percent, resetsAt: reset, durationSeconds: span)
        }
    }

    static func parseReset(_ input: String, now: Date, span: Double) -> Date? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var zone = TimeZone.current
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            guard let parsed = TimeZone(identifier: name) else { return nil }
            zone = parsed
            text = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: " at ", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.replacingOccurrences(of: #"(\d)\s*([ap]m)$"#, with: "$1$2", options: [.regularExpression, .caseInsensitive])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.isLenient = false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        let ceiling = now.addingTimeInterval(span + 2 * 3600)
        var possibilities: [Date] = []
        for time in ["h:mma", "ha"] {
            for (candidate, format) in [(text, "MMM d yyyy \(time)")] +
                (year - 1...year + 1).map({ (text + " \($0)", "MMM d \(time) yyyy") }) {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) { possibilities.append(date) }
            }
            formatter.dateFormat = "yyyy-MM-dd \(time)"
            for offset in -1...1 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let prefix = String(format: "%04d-%02d-%02d ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
                if let date = formatter.date(from: prefix + text) { possibilities.append(date) }
            }
        }
        return possibilities.filter { $0 > now && $0 <= ceiling }.min()
            ?? possibilities.filter { $0 <= now && now.timeIntervalSince($0) <= span + 7200 }.max()
    }
}

func cleanQuotaIdentity(_ string: String) -> String? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
          trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return trimmed
}

func quotaOpaqueIdentity(prefix: String, components: [String]) -> String {
    let digest = SHA256.hash(data: Data(components.joined(separator: "\u{0}").utf8))
    return prefix + ":" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

func quotaLocalJSON(_ url: URL) -> [String: Any]? {
    guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          attrs.isRegularFile == true, let size = attrs.fileSize, size <= 8 * 1024 * 1024,
          let bytes = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: bytes) else { return nil }
    return json as? [String: Any]
}

enum QuotaSubprocess {
    static var clientEnvironment: [String: String] {
        let allowed: Set<String> = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "TZ", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
        ]
        var result = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result["LANG"] = "en_US.UTF-8"
        result["LC_ALL"] = "en_US.UTF-8"
        result["DISABLE_TELEMETRY"] = "1"
        result["DISABLE_ERROR_REPORTING"] = "1"
        result["DISABLE_AUTOUPDATER"] = "1"
        return result
    }

    private final class Output: @unchecked Sendable {
        var data: Data? = nil
    }

    static func read(_ executable: URL, args: [String], directory: URL = FileManager.default.temporaryDirectory,
                     environment: [String: String] = clientEnvironment, timeout: Double = 4) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let terminated = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let output = Output()
        process.terminationHandler = { _ in terminated.signal() }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            var data = Data()
            var tooLarge = false
            while let block = try? pipe.fileHandleForReading.read(upToCount: 16 * 1024), !block.isEmpty {
                if data.count + block.count > 512 * 1024 { tooLarge = true }
                if !tooLarge { data.append(block) }
            }
            if !tooLarge { output.data = data }
        }
        if terminated.wait(timeout: .now() + timeout) != .success {
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard drained.wait(timeout: .now() + 0.5) == .success, process.terminationStatus == 0 else { return nil }
        return output.data
    }
}
