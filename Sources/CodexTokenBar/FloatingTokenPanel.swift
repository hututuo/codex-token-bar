import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

@MainActor
final class FloatingTokenPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    @Published var lockTargetDescription: String?

    private static weak var activeController: FloatingTokenPanelController?
    private static let panelIdentifier = NSUserInterfaceItemIdentifier("CodexTokenBarFloatingTokenPanel")

    var panel: NSPanel?
    private var onClose: (() -> Void)?
    private var onToggleLock: (() -> Void)?
    var lastExternalActivePID: pid_t?
    var lastExternalClickLocation: NSPoint?
    var lastExternalClickAt: Date?
    var lastExternalClickWindowNumber: Int?
    var lastExternalClickOwnerPID: pid_t?
    var lastExternalClickAXWindow: AXUIElement?
    var lockedAnchor: FloatingPanelWindowAnchor?
    var followTimer: Timer?
    var followTimerInterval: TimeInterval?
    var fastFollowUntil: Date?
    var accessibilityObserver: AXObserver?
    var observedAccessibilityWindow: AXUIElement?
    var activeLockedTargetDrag: FloatingPanelLockedTargetDrag?
    var pendingLockedOriginToPersist: NSPoint?
    var lockedOriginPersistTimer: Timer?
    var lastLockedOriginPersistAt = Date.distantPast
    var strictVisibleWindowCache: FloatingPanelWindowListCache?
    var relaxedVisibleWindowCache: FloatingPanelWindowListCache?
    nonisolated(unsafe) private var globalMouseMonitor: Any?
    var isProgrammaticPanelMove = false
    var appliedLockState = false
    let recentExternalClickTargetInterval: TimeInterval = 5 * 60
    let fastFollowInterval: TimeInterval = 1.0 / 60.0
    let idleFollowInterval: TimeInterval = 2.0
    let fastFollowGracePeriod: TimeInterval = 1.2
    let lockedOriginPersistInterval: TimeInterval = 0.45
    let visibleWindowListRefreshInterval: TimeInterval = 1.0
    let screenPositionLockDescription = "屏幕位置"
    let lockTargetDescriptionKey = "floatingPanelLockTargetDescription"
    let lockedOriginXKey = "floatingPanelLockedOriginX"
    let lockedOriginYKey = "floatingPanelLockedOriginY"

    nonisolated static let accessibilityObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<FloatingTokenPanelController>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor in
            controller.handleAccessibilityWindowEvent()
        }
    }

    override init() {
        super.init()
        lastExternalActivePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                switch event.type {
                case .leftMouseDown:
                    self?.recordExternalMouseClick(at: location)
                case .leftMouseDragged:
                    self?.recordExternalMouseDrag(at: location)
                case .leftMouseUp:
                    self?.finishExternalMouseDrag(at: location)
                default:
                    break
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    private static func claimActiveController(_ controller: FloatingTokenPanelController) {
        if let activeController, activeController !== controller {
            activeController.closePanel(destroy: true, unregisterActive: false)
        }
        activeController = controller
    }

    private static func unregisterActiveController(_ controller: FloatingTokenPanelController) {
        if activeController === controller {
            activeController = nil
        }
    }

    private static func closeStrayPanels(except keptPanel: NSPanel?) {
        for window in NSApp.windows {
            guard let panel = window as? NSPanel,
                  panel.identifier == panelIdentifier,
                  panel !== keptPanel
            else {
                continue
            }
            panel.delegate = nil
            panel.contentViewController = nil
            panel.orderOut(nil)
            panel.close()
        }
    }

    private func closePanel(destroy: Bool, unregisterActive: Bool) {
        stopFollowingAnchor()
        let existingPanel = panel
        panel = nil
        onClose = nil
        onToggleLock = nil
        isPresented = false
        appliedLockState = false

        if unregisterActive {
            Self.unregisterActiveController(self)
        }

        guard let existingPanel else { return }
        if destroy {
            existingPanel.delegate = nil
            existingPanel.contentViewController = nil
            existingPanel.orderOut(nil)
            existingPanel.close()
        } else {
            existingPanel.orderOut(nil)
        }
    }

    func show(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        taskCompletionMonitor: TaskCompletionMonitor,
        scale: Double,
        isLocked: Bool,
        onToggleLock: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        Self.claimActiveController(self)
        self.onClose = onClose
        self.onToggleLock = onToggleLock

        if panel == nil {
            let hostingController = NSHostingController(
                rootView: FloatingTokenPanelView(
                    store: store,
                    monitor: monitor,
                    quota: quota,
                    taskCompletionMonitor: taskCompletionMonitor,
                    isLocked: isLocked,
                    lockTargetDescription: lockTargetDescription,
                    onToggleLock: { [weak self] in
                        self?.onToggleLock?()
                    },
                    onClose: { [weak self] in
                        self?.onClose?()
                    }
                )
            )
            let initialSize = FloatingTokenPanelMetrics.size(scale: scale)
            hostingController.view.frame = NSRect(origin: .zero, size: initialSize)
            hostingController.view.autoresizingMask = [.width, .height]

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = Self.panelIdentifier
            panel.contentViewController = hostingController
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = !isLocked
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.delegate = self
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = FloatingTokenPanelMetrics.cornerRadius(scale: scale)
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
            position(panel)
            self.panel = panel
        }
        Self.closeStrayPanels(except: panel)

        if let hostingController = panel?.contentViewController as? NSHostingController<FloatingTokenPanelView> {
            hostingController.rootView = FloatingTokenPanelView(
                store: store,
                monitor: monitor,
                quota: quota,
                taskCompletionMonitor: taskCompletionMonitor,
                isLocked: isLocked,
                lockTargetDescription: lockTargetDescription,
                onToggleLock: { [weak self] in
                    self?.onToggleLock?()
                },
                onClose: { [weak self] in
                    self?.onClose?()
                }
            )
        }

        let wasPresented = isPresented
        updateSize(scale: scale)
        updateLockState(isLocked, force: !wasPresented)
        panel?.orderFrontRegardless()
        isPresented = true
    }

    func updateSize(scale: Double) {
        guard let panel else { return }
        isProgrammaticPanelMove = true
        resizePanel(panel, scale: scale)
        panel.contentView?.layer?.cornerRadius = FloatingTokenPanelMetrics.cornerRadius(scale: scale)
        saveLockedOrigin(panel.frame.origin)
        refreshLockedAnchorOffsetForCurrentFrame()
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticPanelMove = false
        }
    }

    func close() {
        closePanel(destroy: true, unregisterActive: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let closingPanel = notification.object as? NSPanel,
           closingPanel.identifier == Self.panelIdentifier,
           closingPanel === panel {
            panel = nil
        }
        stopFollowingAnchor()
        onClose = nil
        onToggleLock = nil
        isPresented = false
        Self.unregisterActiveController(self)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        guard !isProgrammaticPanelMove else { return }
        saveLockedOrigin(panel.frame.origin)
        if lockedAnchor != nil {
            lockedAnchor = currentAnchor(for: panel)
            lockTargetDescription = lockedAnchor?.targetDescription
            refreshFloatingPanelLockStatus()
        }
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalActivePID = app.processIdentifier
    }


}

struct FloatingTokenPanelView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var taskCompletionMonitor: TaskCompletionMonitor
    let isLocked: Bool
    var lockTargetDescription: String?
    let onToggleLock: () -> Void
    @AppStorage("floatingPanelOpacity") private var floatingPanelOpacity = 0.88
    @AppStorage("floatingPanelScale") private var floatingPanelScale = FloatingTokenPanelMetrics.defaultScale
    @AppStorage(FloatingPanelAppearance.startHexKey) private var floatingPanelGradientStartHex = FloatingPanelAppearance.defaultStartHex
    @AppStorage(FloatingPanelAppearance.endHexKey) private var floatingPanelGradientEndHex = FloatingPanelAppearance.defaultEndHex
    @AppStorage(FloatingPanelAppearance.directionKey) private var floatingPanelGradientDirection = FloatingPanelAppearance.defaultDirection
    @AppStorage(FloatingPanelAppearance.styleKey) private var floatingPanelGradientStyle = FloatingPanelAppearance.defaultStyle
    @AppStorage(FloatingPanelAppearance.unreadEffectKey) private var floatingPanelUnreadEffect = FloatingPanelAppearance.defaultUnreadEffect
    @AppStorage(FloatingPanelAppearance.unreadPreviewUntilKey) private var floatingPanelUnreadPreviewUntil = 0.0
    let onClose: () -> Void

    var body: some View {
        let unreadCount = taskCompletionMonitor.unreadThreadCount
        let unreadEffect = FloatingPanelUnreadEffect(rawValue: floatingPanelUnreadEffect) ?? .ripple
        let isPreviewingUnreadEffect = unreadCount == 0
            && unreadEffect != .off
            && floatingPanelUnreadPreviewUntil > Date.timeIntervalSinceReferenceDate
        let shouldShowUnreadEffect = unreadEffect != .off && (unreadCount > 0 || isPreviewingUnreadEffect)
        let scale = FloatingTokenPanelMetrics.clampedScale(floatingPanelScale)
        let size = FloatingTokenPanelMetrics.size(scale: floatingPanelScale)
        let cornerRadius = FloatingTokenPanelMetrics.cornerRadius(scale: floatingPanelScale)
        let appearance = FloatingPanelAppearance(
            startHex: floatingPanelGradientStartHex,
            endHex: floatingPanelGradientEndHex,
            directionRaw: floatingPanelGradientDirection,
            styleRaw: floatingPanelGradientStyle
        )

        return ZStack {
            TokenGlassBackground(
                opacity: floatingPanelOpacity,
                cornerRadius: cornerRadius,
                appearance: appearance
            )
            if shouldShowUnreadEffect {
                FloatingUnreadEffectOverlay(
                    effect: unreadEffect,
                    color: appearance.unreadIndicatorColor,
                    cornerRadius: cornerRadius,
                    scale: scale
                )
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            TokenDisplayCard(
                snapshot: TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota),
                onClose: nil,
                lockState: nil,
                lockTargetDescription: nil,
                onToggleLock: nil
            )
                .environment(\.tokenDisplayScale, scale)
                .padding(.horizontal, FloatingTokenPanelMetrics.horizontalPadding * scale)
                .padding(.vertical, FloatingTokenPanelMetrics.verticalPadding * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .zIndex(2)

            FloatingPanelLockButton(
                state: isLocked ? .locked : .unlocked,
                targetDescription: lockTargetDescription,
                scale: scale,
                action: onToggleLock
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zIndex(4)

            FloatingPanelCloseButton(
                scale: scale,
                action: onClose
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(4)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: unreadCount > 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func withLockTarget(_ description: String?) -> FloatingTokenPanelView {
        var copy = self
        copy.lockTargetDescription = description
        return copy
    }
}

@MainActor
func resizePanel(_ panel: NSPanel, scale: Double) {
    let previousFrame = panel.frame
    let topLeft = NSPoint(x: previousFrame.minX, y: previousFrame.maxY)
    let targetSize = FloatingTokenPanelMetrics.size(scale: scale)
    let targetFrame = anchoredPanelFrame(for: panel, size: targetSize, topLeft: topLeft)
    panel.contentViewController?.view.frame = NSRect(origin: .zero, size: targetSize)
    panel.contentMinSize = targetSize
    panel.contentMaxSize = targetSize
    panel.setFrame(targetFrame, display: true, animate: false)
}

@MainActor
func anchoredPanelFrame(for panel: NSPanel, size: NSSize, topLeft: NSPoint) -> NSRect {
    let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)

    if let screenFrame {
        let margin: CGFloat = 8
        origin.x = min(max(origin.x, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        origin.y = min(max(origin.y, screenFrame.minY + margin), screenFrame.maxY - size.height - margin)
    }

    return NSRect(origin: origin, size: size)
}
