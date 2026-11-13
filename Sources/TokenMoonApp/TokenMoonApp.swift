// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import TokenMoonCore

/// AppKit owns the menus and window lifetimes; SwiftUI renders their content.
/// No scene recreates the application menus when focus or usage data changes.
@main
@MainActor
final class TokenMoonApplication: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private lazy var windows = MoonDesktopWindows(model: model)
    private var statusItem: MoonStatusController?
    private let loginLaunch: Bool

    private init(loginLaunch: Bool) {
        self.loginLaunch = loginLaunch
        super.init()
    }

    static func main() {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--provision-webdav" { exit(provisionWebDAV(args)) }
        if let command = args.dropFirst().first,
           command == "--verify-webdav-keychain" || command == "--authorize-webdav-keychain" {
            exit(args.count == 2 ? verifyWebDAVKeychain(interactive: command == "--authorize-webdav-keychain") : 64)
        }
        // Finder normally reuses an existing application, but a concurrent
        // installer, login helper, or explicit launch can start another process.
        // Take ownership before creating a status item or touching the ledger.
        let instanceLock: Int32
        do {
            guard let lock = try lockRuntime() else { return }
            instanceLock = lock
        } catch {
            FileHandle.standardError.write(Data("TokenMoon could not acquire its runtime lock.\n".utf8))
            return
        }
        defer { _ = close(instanceLock) }
        let app = NSApplication.shared
        let loginLaunch = args.dropFirst().first == "--login-launch"
        let delegate = TokenMoonApplication(loginLaunch: loginLaunch)
        app.delegate = delegate
        app.setActivationPolicy(loginLaunch ? .accessory : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func lockRuntime() throws -> Int32? {
        // Match AppModel's isolated QA preference domain. All ordinary copies
        // of TokenMoon on this Mac share the same per-user lock.
        let namespace = ProcessInfo.processInfo.environment["TOKENMOON_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent }
        let filename = "org.tokenmoon.desktop.runtime" + (namespace.map { ".qa-" + $0 } ?? "") + ".lock"
        // Use a stable location regardless of the caller's temporary directory.
        let directory = URL.applicationSupportDirectory.appending(path: "TokenMoon Community", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(filename)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid() else {
            _ = close(fd)
            throw POSIXError(.EACCES)
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        let failure = errno
        _ = close(fd)
        if failure == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    /// A staged update must read the configured credential under its own
    /// signature before the installer stops the running app.
    private static func verifyWebDAVKeychain(interactive: Bool) -> Int32 {
        let defaults = UserDefaults.standard
        guard let rawURL = defaults.string(forKey: "webDAVURL"),
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let username = defaults.string(forKey: "webDAVUsername"), !username.isEmpty else { return 2 }
        do {
            func savedPassword() throws -> String? {
                try WebDAVPassword.read(url: url, username: username)
            }
            // Only an explicit one-time migration request may show the native
            // Keychain authorization prompt. The regular install check never does.
            let password = try interactive ? savedPassword() : WebDAVPassword.withoutUserInteraction(savedPassword)
            return password?.isEmpty == false ? 0 : 1
        } catch {
            return 1
        }
    }

    /// Run the installed executable in the login session so it owns its own
    /// Keychain item. Accept the password only from a pipe or standard input file.
    private static func provisionWebDAV(_ args: [String]) -> Int32 {
        guard args.count == 4, isatty(STDIN_FILENO) == 0, let url = URL(string: args[2]),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !args[3].isEmpty, !args[3].contains(":"),
              args[3].rangeOfCharacter(from: .controlCharacters) == nil else {
            FileHandle.standardError.write(Data("Usage: --provision-webdav HTTPS_DIRECTORY USERNAME < password\n".utf8))
            return 64
        }
        do {
            var data = Data()
            while let bytes = try FileHandle.standardInput.read(upToCount: 4097 - data.count), !bytes.isEmpty {
                data.append(bytes)
                guard data.count <= 4096 else { return 64 }
            }
            guard !data.isEmpty, !data.contains(0), !data.contains(10), !data.contains(13),
                  let password = String(data: data, encoding: .utf8) else { return 64 }
            let verified = try WebDAVPassword.withoutUserInteraction {
                try WebDAVPassword.save(password, url: url, username: args[3])
                return try WebDAVPassword.read(url: url, username: args[3]) == password
            }
            guard verified else { return 1 }
            print("TokenMoon password stored and verified in login keychain")
            return 0
        } catch {
            // Do not emit request, argument, or password contents.
            FileHandle.standardError.write(Data(("Keychain provisioning failed: " + error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = MoonMainMenu.build(actions: .init(
            about: { NSApp.orderFrontStandardAboutPanel(nil) },
            settings: { [weak self] in self?.showSettings() },
            showDashboard: { [weak self] in self?.showDashboard() },
            toggleSidebar: { [weak self] in self?.windows.toggleSidebar() },
            canToggleSidebar: { [weak self] in self?.windows.isDashboardKey ?? false },
            refresh: { [weak self] in self?.model.refresh() },
            sync: { [weak self] in self?.model.sync() }
        ))
        NSApp.mainMenu = menu
        statusItem = MoonStatusController(
            model: model, mainMenu: menu, keepMenuBarAccess: loginLaunch,
            openDashboard: { [weak self] in self?.showDashboard() },
            openSettings: { [weak self] in self?.showSettings() }
        )
        if !loginLaunch { windows.showDashboard() }
        model.start()
    }

    private func showDashboard() {
        activateWindowMode()
        windows.showDashboard()
    }

    private func showSettings() {
        activateWindowMode()
        windows.showSettings()
    }

    private func activateWindowMode() {
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
            statusItem?.restoreMenuBarPreference()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return true
    }

    func applicationDidHide(_ notification: Notification) { windows.updateDashboardWindowVisibility() }
    func applicationDidUnhide(_ notification: Notification) { windows.updateDashboardWindowVisibility() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
