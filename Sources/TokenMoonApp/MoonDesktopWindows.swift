// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

@MainActor
final class MoonDesktopWindows: NSObject, NSWindowDelegate {
    private static let dashboardSize = NSSize(width: 1280, height: 820)
    private static let dashboardMinimum = NSSize(width: 920, height: 620)
    private static let dashboardFrameName = "TokenMoonDashboard"
    private static let settingsSize = NSSize(width: 600, height: 600)
    private static let settingsPaneKey = "selectedSettingsPane"

    private let model: AppModel
    private let navigation = DashboardNavigation()
    private(set) var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isDashboardKey: Bool {
        guard let mainWindow else { return false }
        return NSApp.keyWindow === mainWindow
    }

    func showDashboard() {
        let window: NSWindow
        if let mainWindow {
            window = mainWindow
        } else {
            window = makeDashboard()
            mainWindow = window
        }
        present(window)
        updateDashboardWindowVisibility()
    }

    func updateDashboardWindowVisibility() {
        guard let window = mainWindow else { return }
        model.setDashboardWindowVisible(window.isVisible && !window.isMiniaturized && !NSApp.isHidden)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindow = nil
        model.releaseClosedDashboard()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateDashboardWindowVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateDashboardWindowVisibility()
    }

    func showSettings() {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = makeSettings()
            settingsWindow = window
        }
        present(window)
    }

    func toggleSidebar() {
        guard isDashboardKey else { return }
        navigation.toggleSidebar()
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeDashboard() -> NSWindow {
        let host = NSHostingController(rootView: DisplayTimeContext(model: model, content: DashboardView(model: model, navigation: navigation)))
        // Only the local title and toolbar are bridged. The AppKit application
        // delegate owns the application menus for the lifetime of the process.
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.dashboardSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.delegate = self
        window.title = "TokenMoon"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.contentViewController = host
        window.contentMinSize = Self.dashboardMinimum
        window.setContentSize(Self.dashboardSize)
        if !window.setFrameUsingName(Self.dashboardFrameName) { window.center() }
        window.setFrameAutosaveName(Self.dashboardFrameName)
        return window
    }

    private func makeSettings() -> NSWindow {
        let tabs = MoonSettingsTabs()
        tabs.tabStyle = .unspecified
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: DisplayTimeContext(model: model, content: TokenMoonSettingsView(model: model, pane: pane)))
            host.sceneBridgingOptions = []
            host.sizingOptions = []
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.identifier = pane.rawValue
            item.label = pane.title
            tabs.addTabViewItem(item)
        }

        let defaults = UserDefaults.standard
        let initialPane = defaults.string(forKey: Self.settingsPaneKey).flatMap(SettingsPane.init(rawValue:)) ?? .appearance
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: initialPane) ?? 0
        let window = NSWindow(contentViewController: tabs)
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.styleMask = [.titled, .closable]
        window.toolbar = tabs.makeToolbar()
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.title = initialPane.title
        window.setContentSize(Self.settingsSize)
        window.center()
        tabs.onSelect = { [weak window] pane in
            defaults.set(pane.rawValue, forKey: Self.settingsPaneKey)
            window?.title = pane.title
        }
        return window
    }
}

@MainActor
private final class MoonSettingsTabs: NSTabViewController {
    private static let paneControlID = NSToolbarItem.Identifier("TokenMoonSettingsPaneControl")
    private static let paneWidth: CGFloat = 74
    private var paneControl: NSSegmentedControl?
    var onSelect: ((SettingsPane) -> Void)?

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "TokenMoonSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.paneControlID]
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.paneControlID]
    }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.paneControlID]
    }

    override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                          willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.paneControlID else { return nil }
        let panes = SettingsPane.allCases
        let control = NSSegmentedControl(labels: panes.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(selectPane(_:)))
        control.segmentStyle = .automatic
        control.controlSize = .large
        control.setAccessibilityLabel("设置分类")
        for index in panes.indices {
            control.setWidth(Self.paneWidth, forSegment: index)
        }
        control.selectedSegment = selectedTabViewItemIndex
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "设置分类"
        item.view = control
        if flag { paneControl = control }
        return item
    }

    @objc private func selectPane(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        if tabViewItems.indices.contains(index) { selectedTabViewItemIndex = index }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let identifier = tabViewItem?.identifier as? String,
              let pane = SettingsPane(rawValue: identifier) else { return }
        if let index = SettingsPane.allCases.firstIndex(of: pane) { paneControl?.selectedSegment = index }
        onSelect?(pane)
    }
}
