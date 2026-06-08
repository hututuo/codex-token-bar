import AppKit
import SwiftUI

@MainActor
final class FloatingTokenPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false

    private var panel: NSPanel?
    private var onClose: (() -> Void)?

    func show(store: CodexUsageStore, monitor: LiveRateMonitor, onClose: @escaping () -> Void) {
        self.onClose = onClose

        if panel == nil {
            let hostingController = NSHostingController(
                rootView: FloatingTokenPanelView(store: store, monitor: monitor) { [weak self] in
                    self?.onClose?()
                }
            )

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 166, height: 46),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.delegate = self
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = 14
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
            position(panel)
            self.panel = panel
        }

        panel?.orderFrontRegardless()
        isPresented = true
    }

    func close() {
        panel?.orderOut(nil)
        isPresented = false
    }

    func windowWillClose(_ notification: Notification) {
        isPresented = false
        onClose?()
    }

    private func position(_ panel: NSPanel) {
        let anchorWindow = NSApp.windows.first {
            $0 !== panel && $0.isVisible && !($0 is NSPanel)
        }
        let screenFrame = anchorWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let screenFrame else {
            panel.center()
            return
        }

        let margin: CGFloat = 22
        let topInset: CGFloat = 210
        let anchorFrame = anchorWindow?.frame ?? screenFrame
        let origin = NSPoint(
            x: min(anchorFrame.minX + margin, screenFrame.maxX - panel.frame.width - margin),
            y: min(anchorFrame.maxY - panel.frame.height - topInset, screenFrame.maxY - panel.frame.height - topInset)
        )
        panel.setFrameOrigin(NSPoint(x: max(screenFrame.minX + margin, origin.x), y: max(screenFrame.minY + margin, origin.y)))
    }
}

struct FloatingTokenPanelView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    let onClose: () -> Void

    var body: some View {
        ZStack {
            TokenGlassBackground()
            TokenDisplayCard(snapshot: TokenDisplaySnapshot.make(store: store, monitor: monitor), onClose: onClose)
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .offset(x: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(width: 166, height: 46)
    }
}
