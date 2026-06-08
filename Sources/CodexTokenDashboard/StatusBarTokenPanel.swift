import AppKit
import SwiftUI

@MainActor
final class StatusBarTokenController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var isPresented = false

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private weak var store: CodexUsageStore?
    private weak var monitor: LiveRateMonitor?
    private var onClose: (() -> Void)?

    func show(store: CodexUsageStore, monitor: LiveRateMonitor, onClose: @escaping () -> Void) {
        self.store = store
        self.monitor = monitor
        self.onClose = onClose

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: 78)
            item.button?.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Codex token rate")
            item.button?.imagePosition = .imageLeading
            item.button?.contentTintColor = .controlAccentColor
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.toolTip = "Codex token rate"
            statusItem = item
        }

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            popover.contentSize = NSSize(width: 276, height: 140)
            popover.contentViewController = NSHostingController(
                rootView: StatusBarTokenPopoverView(store: store, monitor: monitor) { [weak self] in
                    self?.onClose?()
                }
            )
            self.popover = popover
        }

        updateStatusItem()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }
        isPresented = true
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
        timer?.invalidate()
        timer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        isPresented = false
    }

    func popoverDidClose(_ notification: Notification) {
        updateStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateStatusItem() {
        guard let store, let monitor else { return }
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor)
        guard let button = statusItem?.button else { return }
        button.title = " \(snapshot.statusBarTitle)"
        button.alignment = .center
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }
}

struct StatusBarTokenPopoverView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    let onClose: () -> Void

    var body: some View {
        ZStack {
            TokenGlassBackground()
            TokenDisplayCard(snapshot: TokenDisplaySnapshot.make(store: store, monitor: monitor), onClose: onClose)
                .padding(14)
        }
        .frame(width: 276, height: 140)
    }
}
