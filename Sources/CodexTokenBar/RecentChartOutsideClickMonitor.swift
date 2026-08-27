import AppKit
import SwiftUI

/// Observes same-window clicks without taking hit testing away from the chart
/// or the surrounding dashboard. The represented view adopts the full bounds
/// of the chart section through its background placement.
struct RecentChartOutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: MonitoringView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: MonitoringView, coordinator: Void) {
        nsView.stopMonitoring()
    }

    final class MonitoringView: NSView {
        var onOutsideClick: (() -> Void)?
        private var eventMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restartMonitoring()
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        private func restartMonitoring() {
            stopMonitoring()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        func observe(_ event: NSEvent) {
            observeClick(in: event.window, locationInWindow: event.locationInWindow)
        }

        func observeClick(in eventWindow: NSWindow?, locationInWindow: NSPoint) {
            guard let window, eventWindow === window else { return }
            let localPoint = convert(locationInWindow, from: nil)
            observeLocalClick(localPoint)
        }

        func observeLocalClick(_ localPoint: NSPoint) {
            guard !bounds.contains(localPoint) else { return }
            onOutsideClick?()
        }
    }
}
