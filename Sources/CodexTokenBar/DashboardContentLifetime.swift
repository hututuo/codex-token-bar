import AppKit
import SwiftUI

/// SwiftUI keeps a Window's hosting tree after its close button is pressed.
/// Keep a tiny shell alive for reopening, and discard its chart/view caches
/// while the window is closed or minimized. App-owned readers keep running.
struct DashboardContentLifetime<Content: View>: View {
    @State private var mounted = true
    @State private var unloadTask: Task<Void, Never>?
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if mounted { content() }
            else { Color.clear }
        }
        .background(DashboardWindowVisibility { isVisible in
            unloadTask?.cancel()
            unloadTask = nil
            if isVisible {
                mounted = true
            } else {
                // A SwiftUI .task is cancelled when the window disappears,
                // exactly when this delayed unload needs to keep running.
                unloadTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard !Task.isCancelled else { return }
                    mounted = false
                    unloadTask = nil
                    ProcessMemoryReclaimer.schedule()
                }
            }
        })
    }
}

private struct DashboardWindowVisibility: NSViewRepresentable {
    var changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.changed = changed
    }

    final class ObserverView: NSView {
        var changed: (@MainActor (Bool) -> Void)?
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)),
                                                       name: name, object: window)
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)),
                                                       name: name, object: nil)
            }
            DispatchQueue.main.async { [weak self] in self?.reportVisibility() }
        }

        @objc private func windowChanged(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification {
                report(false)
            } else {
                reportVisibility()
            }
        }

        private func reportVisibility() {
            guard let window else { return }
            report(window.isVisible && !window.isMiniaturized && !NSApp.isHidden)
        }

        private func report(_ visible: Bool) {
            guard visible != lastVisible else { return }
            lastVisible = visible
            changed?(visible)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
