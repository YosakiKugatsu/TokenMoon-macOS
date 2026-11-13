// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

extension View {
    /// Opt-in for a SwiftUI `Table`: attach to the first column's cell content. A tiny marker
    /// inside the row finds the table's own `NSScrollView` and turns off its vertical rubber band,
    /// which `scrollBounceBehavior(.basedOnSize)` keeps once rows overflow and shows as top-edge
    /// jitter. Scrolling, row virtualization, mouse and keyboard are untouched.
    func moonTableScrollClamp(_ enabled: Bool = true) -> some View {
        background {
            if enabled { MoonTableScrollClampMarker().frame(width: 1, height: 1).accessibilityHidden(true) }
        }
    }
}

private struct MoonTableScrollClampMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleClamp()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleClamp()
        }

        private func scheduleClamp() {
            guard window != nil else { return }
            // Row views are attached to the table after this marker is installed.
            Task { @MainActor [weak self] in self?.clamp() }
        }

        private func clamp() {
            guard window != nil, let scrollView = enclosingScrollView,
                  let document = scrollView.documentView, isDescendant(of: document),
                  document is NSTableView || Self.containsTable(document) else { return }
            if scrollView.verticalScrollElasticity != .none { scrollView.verticalScrollElasticity = .none }
        }

        private static func containsTable(_ view: NSView) -> Bool {
            view.subviews.contains { $0 is NSTableView || containsTable($0) }
        }
    }
}
