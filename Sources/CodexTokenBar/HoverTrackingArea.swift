import AppKit
import SwiftUI

struct HoverTrackingArea: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    var onClick: ((CGPoint) -> Void)? = nil
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        view.onClick = onClick
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
        nsView.onClick = onClick
        nsView.onExit = onExit
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onClick: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        private var currentTrackingArea: NSTrackingArea?

        override var isFlipped: Bool {
            true
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard currentTrackingArea == nil else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            currentTrackingArea = area
            addTrackingArea(area)
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}
