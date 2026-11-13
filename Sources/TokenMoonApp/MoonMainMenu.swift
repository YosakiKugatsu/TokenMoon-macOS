// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Installs one AppKit menu tree for the app lifetime. Collection and SwiftUI
/// view updates never rebuild its items.
@MainActor
enum MoonMainMenu {
    struct Actions {
        let about: () -> Void
        let settings: () -> Void
        let showDashboard: () -> Void
        let toggleSidebar: () -> Void
        let canToggleSidebar: () -> Bool
        let refresh: () -> Void
        let sync: () -> Void
    }

    static func build(actions: Actions) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "TokenMoon")
        app.addItem(ActionItem("关于 TokenMoon", perform: actions.about))
        app.addItem(.separator())
        app.addItem(ActionItem("设置…", key: ",", perform: actions.settings))
        app.addItem(.separator())
        let services = NSMenu(title: "服务")
        app.addItem(submenuItem(services))
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(native("隐藏 TokenMoon", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(native("隐藏其他应用", #selector(NSApplication.hideOtherApplications(_:)),
                           key: "h", modifiers: [.command, .option]))
        app.addItem(native("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(native("退出 TokenMoon", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenuItem(app))

        let file = NSMenu(title: "文件")
        file.addItem(ActionItem("采集本机用量", key: "r", perform: actions.refresh))
        file.addItem(ActionItem("同步 WebDAV", key: "s", modifiers: [.command, .shift], perform: actions.sync))
        file.addItem(.separator())
        file.addItem(native("关闭窗口", #selector(NSWindow.performClose(_:)), key: "w"))
        main.addItem(submenuItem(file))

        let edit = NSMenu(title: "编辑")
        edit.addItem(native("撤销", NSSelectorFromString("undo:"), key: "z"))
        edit.addItem(native("重做", NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(native("剪切", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(native("拷贝", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(native("粘贴", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(native("删除", #selector(NSText.delete(_:))))
        edit.addItem(native("全选", #selector(NSText.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        edit.addItem(native("开始听写…", NSSelectorFromString("startDictation:")))
        edit.addItem(native("表情与符号", #selector(NSApplication.orderFrontCharacterPalette(_:)),
                            key: " ", modifiers: [.command, .control]))
        main.addItem(submenuItem(edit))

        let view = NSMenu(title: "显示")
        view.addItem(ActionItem("显示或隐藏边栏", key: "s", modifiers: [.command, .control],
                                available: actions.canToggleSidebar, perform: actions.toggleSidebar))
        view.addItem(native("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)),
                            key: "f", modifiers: [.command, .control]))
        main.addItem(submenuItem(view))

        let window = NSMenu(title: "窗口")
        window.addItem(native("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(native("缩放", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(ActionItem("打开主窗口", key: "o", perform: actions.showDashboard))
        window.addItem(.separator())
        window.addItem(native("全部移到最前", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        main.addItem(submenuItem(window))

        let help = NSMenu(title: "帮助")
        NSApp.helpMenu = help
        main.addItem(submenuItem(help))
        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// No explicit target: AppKit locates and validates the active responder.
    private static func native(_ title: String, _ action: Selector, key: String = "",
                               modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

@MainActor
private final class ActionItem: NSMenuItem, NSMenuItemValidation {
    private let available: () -> Bool
    private let perform: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         available: @escaping () -> Bool = { true }, perform: @escaping () -> Void) {
        self.available = available
        self.perform = perform
        super.init(title: title, action: nil, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        action = #selector(invoke(_:))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("ActionItem is created in code") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { available() }

    @objc private func invoke(_ sender: NSMenuItem) {
        if available() { perform() }
    }
}
