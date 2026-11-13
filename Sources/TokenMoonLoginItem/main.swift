// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let appID = "org.tokenmoon.desktop"

@MainActor
func launchTokenMoon() async {
    let helper = Bundle.main.bundleURL.standardizedFileURL
    let loginItems = helper.deletingLastPathComponent()
    let library = loginItems.deletingLastPathComponent()
    let contents = library.deletingLastPathComponent()
    let parent = contents.deletingLastPathComponent()
    guard helper.lastPathComponent == "TokenMoonLoginItem.app",
          loginItems.lastPathComponent == "LoginItems",
          library.lastPathComponent == "Library",
          contents.lastPathComponent == "Contents",
          parent.pathExtension == "app",
          let bundle = Bundle(url: parent), bundle.bundleIdentifier == appID,
          bundle.executableURL != nil,
          NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty else { return }

    // Registering a login item can start it immediately. Don't reopen an
    // already-running copy, and at login use this helper's containing bundle.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = false
    configuration.allowsRunningApplicationSubstitution = false
    configuration.promptsUserIfNeeded = false
    configuration.arguments = ["--login-launch"]
    _ = try? await NSWorkspace.shared.openApplication(at: parent, configuration: configuration)
}

await launchTokenMoon()
