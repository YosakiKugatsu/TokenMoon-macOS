// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

extension UsageQuotaInsights.Provider {
    var insightAgentName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
}

enum SubscriptionAgentOrder {
    typealias Provider = UsageQuotaInsights.Provider

    static func restore(_ ids: [String]) -> [Provider] {
        var seen: Set<Provider> = []
        return ids.compactMap(Provider.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    private static func merged(saved: [Provider], available: Set<Provider>) -> [Provider] {
        saved + available.subtracting(saved).sorted { $0.rawValue < $1.rawValue }
    }

    static func visible(saved: [Provider], available: Set<Provider>) -> [Provider] {
        merged(saved: saved, available: available).filter { available.contains($0) }
    }

    static func moving(_ source: Provider, to target: Provider, saved: [Provider],
                       available: Set<Provider>) -> [Provider]? {
        guard source != target, available.contains(source), available.contains(target) else { return nil }
        let order = merged(saved: saved, available: available)
        var visible = order.filter { available.contains($0) }
        guard let start = visible.firstIndex(of: source), let end = visible.firstIndex(of: target) else { return nil }
        let moved = visible.remove(at: start)
        visible.insert(moved, at: end)
        var next = visible.makeIterator()
        // Keep slots for temporarily absent providers so that they can reappear in place.
        return order.map { available.contains($0) ? next.next() ?? $0 : $0 }
    }
}

/// Only the card heading is a drag surface, leaving charts and buttons interactive.
struct SubscriptionAgentCardDrag: ViewModifier {
    let index: Int
    let count: Int
    let changed: (CGPoint) -> Void
    let ended: (CGPoint) -> Void
    let cancelled: () -> Void
    let nudge: (Int) -> KeyPress.Result
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        if count > 1 {
            content
                .contentShape(Rectangle())
                .pointerStyle(isDragging ? .grabActive : .grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 5, coordinateSpace: .global)
                        .updating($isDragging) { _, dragging, _ in dragging = true }
                        .onChanged { changed($0.location) }
                        .onEnded { ended($0.location) }
                )
                .onChange(of: isDragging) { _, active in if !active { cancelled() } }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { nudge(-1) }
                .onKeyPress(.downArrow) { nudge(1) }
                .help("拖动卡片调整顺序，或聚焦后按上下方向键")
                .accessibilityElement(children: .combine)
                .accessibilityValue("第 \(index + 1) 位，共 \(count) 位")
                .accessibilityHint("拖动卡片或用上下方向键排序")
                .accessibilityActions {
                    if index > 0 { Button("向前移动") { _ = nudge(-1) } }
                    if index + 1 < count { Button("向后移动") { _ = nudge(1) } }
                }
        } else {
            content
        }
    }
}
