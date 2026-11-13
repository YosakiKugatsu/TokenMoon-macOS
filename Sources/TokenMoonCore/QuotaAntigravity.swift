// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum AntigravityQuota {
    /// The native CLI's usage report deliberately does not return the
    /// account's email or plan. Do not associate it with another provider.
    static let unidentifiedAccountID = "antigravity:ambient-cli"

    private struct Report: Decodable {
        let status: String
        let numTurns: Int?
        let usage: Consumption?
        let command: Command
        struct Consumption: Decodable { let totalTokens: Int? }
        struct Command: Decodable {
            let name: String
            let data: Groups
        }
        struct Groups: Decodable { let groups: [Group] }
        struct Group: Decodable {
            let name: String?
            let displayName: String?
            let buckets: [Bucket]
        }
        struct Bucket: Decodable {
            let id: String?
            let bucketId: String?
            let name: String?
            let displayName: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let disabled: Bool?
        }
    }

    static func read() async -> [QuotaAccount] {
        await Task.detached(priority: .utility) { readNativeCLI() }.value
    }

    private static func readNativeCLI() -> [QuotaAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            home.appendingPathComponent(".local/bin/agy"),
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })?
            .resolvingSymlinksInPath() else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmoon-agy-quota-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        var env = QuotaSubprocess.clientEnvironment.filter { !$0.key.hasPrefix("CLAUDE_") }
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        guard let versionBytes = QuotaSubprocess.read(executable, args: ["--version"], directory: directory,
                                                      environment: env, timeout: 3),
              let version = String(data: versionBytes, encoding: .utf8), supportsPrintUsage(version) else { return [] }
        // Do not open an authentication flow on a passive quota refresh.
        // The supported client versions resolve these launchers through PATH.
        for launcher in ["open", "xdg-open"] {
            do {
                let file = directory.appendingPathComponent(launcher)
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            } catch { return [] }
        }
        env["PATH"] = directory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["BROWSER"] = directory.appendingPathComponent("open").path
        guard let bytes = QuotaSubprocess.read(executable, args: ["-p", "/usage", "--output-format", "json"],
                                               directory: directory, environment: env, timeout: 12) else { return [] }
        let now = Date()
        let windows = parseUsage(bytes, now: now)
        guard !windows.isEmpty else { return [] }
        return [QuotaAccount(id: unidentifiedAccountID, agent: .antigravity, displayName: "当前 Google 账号",
                             windows: windows, observedAt: now,
                             note: "由官方 CLI 读取；客户端未提供邮箱，不跨次合并账号预测")]
    }

    static func supportsPrintUsage(_ version: String) -> Bool {
        let pattern = #"(?<![\d.])(\d+)\.(\d+)\.(\d+)(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version))
        else { return false }
        let parts = (1...3).compactMap { index -> Int? in
            Range(match.range(at: index), in: version).flatMap { Int(version[$0]) }
        }
        guard parts.count == 3 else { return false }
        return (parts[0], parts[1], parts[2]) >= (1, 1, 11)
    }

    static func parseUsage(_ data: Data, now: Date) -> [QuotaWindow] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report = try? decoder.decode(Report.self, from: data),
              report.status == "SUCCESS", report.command.name == "usage", report.numTurns == 0,
              report.usage?.totalTokens == 0 else { return [] }
        let date = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return report.command.data.groups.flatMap { group -> [QuotaWindow] in
            let name = (group.displayName ?? group.name).flatMap(cleanQuotaIdentity) ?? "模型额度"
            return group.buckets.compactMap { bucket in
                guard bucket.disabled != true, let id = (bucket.bucketId ?? bucket.id).flatMap(cleanQuotaIdentity),
                      let fraction = bucket.remainingFraction, fraction.isFinite, (0...1).contains(fraction)
                else { return nil }
                let reset = bucket.resetTime.flatMap { fractional.date(from: $0) ?? date.date(from: $0) }
                if let reset, reset <= now { return nil }
                let duration: Double?
                let label: String
                switch bucket.window?.lowercased() {
                case "5h": duration = 5 * 3600; label = "5 小时"
                case "weekly", "7d": duration = 7 * 86400; label = "7 天"
                default: duration = nil; label = (bucket.displayName ?? bucket.name).flatMap(cleanQuotaIdentity) ?? id
                }
                return QuotaWindow(id: id, label: name + " · " + label, usedPercent: (1 - fraction) * 100,
                                   resetsAt: reset, durationSeconds: duration)
            }
        }
    }
}
