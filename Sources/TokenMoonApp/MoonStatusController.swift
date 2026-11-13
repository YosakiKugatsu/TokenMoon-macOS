// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Observation
import SwiftUI

@MainActor
final class MoonStatusController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let mainMenu: NSMenu
    private let openDashboard: () -> Void
    private let openSettings: () -> Void
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var pending: (visible: Bool, readout: MoonStatusReadout)?
    private var displayed: MoonStatusReadout?
    private var trackedMenus: Set<ObjectIdentifier> = []
    private var keepMenuBarAccess: Bool

    init(model: AppModel, mainMenu: NSMenu, keepMenuBarAccess: Bool = false,
         openDashboard: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.mainMenu = mainMenu
        self.openDashboard = openDashboard
        self.openSettings = openSettings
        self.keepMenuBarAccess = keepMenuBarAccess
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "TokenMoon"
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(beginMenuTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        notifications.addObserver(self, selector: #selector(endMenuTracking(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        notifications.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observe()
    }

    private func observe() {
        pending = withObservationTracking {
            menuBarState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        applyPending()
    }

    @objc private func screenParametersChanged() {
        pending = menuBarState()
        applyPending()
    }

    private func menuBarState() -> (visible: Bool, readout: MoonStatusReadout) {
        let visible = model.showsMenuBarItem
        return (visible || keepMenuBarAccess, MoonStatusReadout(model: model))
    }

    func restoreMenuBarPreference() {
        guard keepMenuBarAccess else { return }
        keepMenuBarAccess = false
        screenParametersChanged()
    }

    private func applyPending() {
        // Let AppKit finish tracking Edit/View before changing another item in
        // the system menu bar. Data continues to collect during tracking.
        guard trackedMenus.isEmpty, let pending else { return }
        self.pending = nil
        if item.isVisible != pending.visible {
            if !pending.visible { popover.performClose(nil) }
            item.isVisible = pending.visible
        }
        guard let button = item.button, displayed != pending.readout else { return }
        if !pending.readout.hasSameImage(as: displayed) {
            button.image = pending.readout.image()
        }
        button.setAccessibilityLabel(pending.readout.accessibilityLabel)
        button.toolTip = pending.readout.accessibilityLabel
        displayed = pending.readout
    }

    @objc private func beginMenuTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        var ancestor: NSMenu? = menu
        while let current = ancestor {
            if current === mainMenu {
                trackedMenus.insert(ObjectIdentifier(menu))
                return
            }
            ancestor = current.supermenu
        }
    }

    @objc private func endMenuTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              trackedMenus.remove(ObjectIdentifier(menu)) != nil, trackedMenus.isEmpty else { return }
        // Wait until AppKit has unwound its tracking event.
        Task { @MainActor [weak self] in self?.applyPending() }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button, button.window != nil else { return }
        let panel = MoonQuickPanel(
            model: model,
            openDashboard: { [weak self] in
                self?.popover.performClose(nil)
                self?.openDashboard()
            },
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            }
        )
        let hosting = NSHostingController(rootView: DisplayTimeContext(model: model, content: panel))
        hosting.sceneBridgingOptions = []
        hosting.sizingOptions = [.preferredContentSize]
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = hosting
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hosting.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        popover.contentViewController = nil
        // A day or model picked in the popup is a quick look. The next open starts on
        // today's full reading, the same one the menu bar shows; the source stays.
        model.resetQuickLook()
    }
}
