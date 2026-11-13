// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

/// A neutral system symbol identifies the source without embedding vendor artwork.
@MainActor
struct AgentMark: View {
    let agent: Agent
    var size: CGFloat = 16

    private var symbol: String {
        switch agent {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "terminal"
        case .claudeDesktop: "macwindow"
        case .antigravity: "sparkles"
        case .cpa: "network"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
