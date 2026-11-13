// SPDX-License-Identifier: GPL-3.0-only
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginStartController {
    private let service = SMAppService.loginItem(identifier: "org.tokenmoon.desktop.login-item")
    private(set) var isEnabled = false
    private(set) var needsApproval = false
    private(set) var errorMessage: String?

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        guard enabled != (isEnabled || needsApproval) else { return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            refresh()
            if enabled && !isEnabled && !needsApproval {
                errorMessage = "macOS 未启用登录项，请重试。"
            } else if !enabled && (isEnabled || needsApproval) {
                errorMessage = "macOS 未移除登录项，请重试。"
            }
        } catch {
            refresh()
            if enabled ? !isEnabled && !needsApproval : isEnabled || needsApproval {
                errorMessage = "无法\(enabled ? "启用" : "关闭")登录时启动：\(error.localizedDescription)"
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
