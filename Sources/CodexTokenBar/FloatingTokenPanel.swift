import AppKit
import CoreGraphics
import SwiftUI

enum FloatingTokenPanelMetrics {
    static let baseSize = NSSize(width: 201, height: 72)
    static let baseCornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    static let defaultScale = 1.0
    static let scaleRange = 0.75...2.0

    static func clampedScale(_ scale: Double) -> CGFloat {
        CGFloat(min(max(scale, scaleRange.lowerBound), scaleRange.upperBound))
    }

    static func size(scale: Double) -> NSSize {
        let clamped = clampedScale(scale)
        return NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
    }

    static func cornerRadius(scale: Double) -> CGFloat {
        baseCornerRadius * clampedScale(scale)
    }
}

@MainActor
final class FloatingTokenPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    @Published private(set) var lockTargetDescription: String?

    private var panel: NSPanel?
    private var onClose: (() -> Void)?
    private var onToggleLock: (() -> Void)?
    private var lastExternalActivePID: pid_t?
    private var lastExternalClickLocation: NSPoint?
    private var lastExternalClickAt: Date?
    private var lockedAnchor: FloatingPanelWindowAnchor?
    private var followTimer: Timer?
    nonisolated(unsafe) private var globalMouseMonitor: Any?
    private var isProgrammaticPanelMove = false
    private var appliedLockState = false
    private let recentExternalClickTargetInterval: TimeInterval = 45
    private let screenPositionLockDescription = "屏幕位置"
    private let lockedOriginXKey = "floatingPanelLockedOriginX"
    private let lockedOriginYKey = "floatingPanelLockedOriginY"

    override init() {
        super.init()
        lastExternalActivePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.recordExternalMouseClick(at: location)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
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
        panel?.orderOut(nil)
        stopFollowingAnchor()
        isPresented = false
    }

    func windowWillClose(_ notification: Notification) {
        stopFollowingAnchor()
        isPresented = false
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

    private func recordExternalMouseClick(at location: NSPoint) {
        lastExternalClickLocation = location
        lastExternalClickAt = Date()
    }

    private func position(_ panel: NSPanel) {
        if let savedOrigin = savedLockedOrigin() {
            panel.setFrameOrigin(savedOrigin)
            return
        }

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

    private func updateLockState(_ isLocked: Bool, force: Bool = false) {
        guard let panel else { return }
        panel.isMovableByWindowBackground = !isLocked

        guard force || appliedLockState != isLocked else {
            if isLocked, lockedAnchor != nil, followTimer == nil {
                startFollowingAnchor()
            }
            return
        }
        appliedLockState = isLocked

        if isLocked {
            saveLockedOrigin(panel.frame.origin)
            if force && lockedAnchor != nil {
                lockTargetDescription = lockedAnchor?.targetDescription ?? screenPositionLockDescription
                startFollowingAnchor()
                refreshFloatingPanelLockStatus()
                return
            }
            lockedAnchor = currentAnchor(for: panel)
            lockTargetDescription = lockedAnchor?.targetDescription ?? screenPositionLockDescription
            startFollowingAnchor()
        } else {
            lockedAnchor = nil
            lockTargetDescription = nil
            stopFollowingAnchor()
        }
        refreshFloatingPanelLockStatus()
    }

    private func currentAnchor(for panel: NSPanel) -> FloatingPanelWindowAnchor? {
        guard let targetWindow = findTargetWindow(near: panel.frame) else { return nil }
        let offset = NSPoint(
            x: panel.frame.minX - targetWindow.frame.minX,
            y: panel.frame.minY - targetWindow.frame.minY
        )
        return FloatingPanelWindowAnchor(
            windowNumber: targetWindow.windowNumber,
            ownerPID: targetWindow.ownerPID,
            ownerBundleID: targetWindow.ownerBundleID,
            windowTitle: targetWindow.title,
            targetDescription: targetWindow.displayName,
            offset: offset
        )
    }

    private func startFollowingAnchor() {
        followTimer?.invalidate()
        guard lockedAnchor != nil else { return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.followAnchorIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowingAnchor() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func followAnchorIfNeeded() {
        guard let panel, let anchor = lockedAnchor else { return }
        guard let targetWindow = findWindow(matching: anchor) else { return }
        let origin = NSPoint(
            x: targetWindow.frame.minX + anchor.offset.x,
            y: targetWindow.frame.minY + anchor.offset.y
        )
        let frame = anchoredPanelFrame(for: panel, size: panel.frame.size, topLeft: NSPoint(x: origin.x, y: origin.y + panel.frame.height))
        if abs(frame.origin.x - panel.frame.origin.x) > 0.5 || abs(frame.origin.y - panel.frame.origin.y) > 0.5 {
            isProgrammaticPanelMove = true
            panel.setFrameOrigin(frame.origin)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticPanelMove = false
            }
            saveLockedOrigin(frame.origin)
        }
    }

    private func findTargetWindow(near panelFrame: NSRect) -> FloatingPanelTargetWindow? {
        if let clickedWindow = targetWindowAtRecentExternalClick() {
            return clickedWindow
        }

        let windows = visibleWindows()
        let nearestWindow = windows.max { lhs, rhs in
            targetScore(lhs, near: panelFrame) < targetScore(rhs, near: panelFrame)
        }
        if let nearestWindow, overlapArea(nearestWindow.frame, panelFrame) > 0 {
            return nearestWindow
        }

        let targetPID = lastExternalActivePID
        return windows.first { window in
            if let targetPID, window.ownerPID == targetPID {
                return true
            }
            return false
        } ?? nearestWindow
    }

    private func targetWindowAtRecentExternalClick() -> FloatingPanelTargetWindow? {
        guard let location = lastExternalClickLocation,
              let clickAt = lastExternalClickAt,
              Date().timeIntervalSince(clickAt) <= recentExternalClickTargetInterval
        else {
            return nil
        }

        return visibleWindows().first { window in
            windowContainsClick(location, window: window)
        }
    }

    private func windowContainsClick(_ location: NSPoint, window: FloatingPanelTargetWindow) -> Bool {
        if window.frame.contains(location) {
            return true
        }

        let quartzLocation = NSPoint(x: location.x, y: FloatingPanelScreenGeometry.displayMaxY - location.y)
        return window.rawFrame.contains(quartzLocation)
    }

    private func targetScore(_ window: FloatingPanelTargetWindow, near panelFrame: NSRect) -> CGFloat {
        let overlap = overlapArea(window.frame, panelFrame)
        if overlap > 0 {
            return 1_000_000 + overlap
        }
        let dx = window.frame.midX - panelFrame.midX
        let dy = window.frame.midY - panelFrame.midY
        return -((dx * dx) + (dy * dy))
    }

    private func overlapArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func findWindow(matching anchor: FloatingPanelWindowAnchor) -> FloatingPanelTargetWindow? {
        let windows = visibleWindows()
        if let byNumber = windows.first(where: { $0.windowNumber == anchor.windowNumber }) {
            return byNumber
        }
        if let byPID = windows.first(where: { $0.ownerPID == anchor.ownerPID && $0.title == anchor.windowTitle }) {
            return byPID
        }
        if let bundleID = anchor.ownerBundleID,
           let byBundle = windows.first(where: { $0.ownerBundleID == bundleID && $0.title == anchor.windowTitle }) {
            return byBundle
        }
        if let bundleID = anchor.ownerBundleID,
           let byBundle = windows.first(where: { $0.ownerBundleID == bundleID }) {
            return byBundle
        }
        return windows.first(where: { $0.ownerPID == anchor.ownerPID })
    }

    private func refreshLockedAnchorOffsetForCurrentFrame() {
        guard let panel, let anchor = lockedAnchor, let targetWindow = findWindow(matching: anchor) else {
            return
        }
        lockedAnchor = FloatingPanelWindowAnchor(
            windowNumber: anchor.windowNumber,
            ownerPID: anchor.ownerPID,
            ownerBundleID: anchor.ownerBundleID,
            windowTitle: anchor.windowTitle,
            targetDescription: anchor.targetDescription,
            offset: NSPoint(
                x: panel.frame.minX - targetWindow.frame.minX,
                y: panel.frame.minY - targetWindow.frame.minY
            )
        )
        lockTargetDescription = anchor.targetDescription
        refreshFloatingPanelLockStatus()
    }

    private func refreshFloatingPanelLockStatus() {
        guard let hostingController = panel?.contentViewController as? NSHostingController<FloatingTokenPanelView> else {
            return
        }
        hostingController.rootView = hostingController.rootView.withLockTarget(lockTargetDescription)
    }

    private func visibleWindows() -> [FloatingPanelTargetWindow] {
        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return rawWindows.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != currentPID,
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 60,
                  height > 40
            else {
                return nil
            }

            let displayMaxY = FloatingPanelScreenGeometry.displayMaxY
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            guard isLockCandidateWindow(layer: layer, ownerName: ownerName, bundleID: app?.bundleIdentifier) else {
                return nil
            }
            let title = info[kCGWindowName as String] as? String ?? ""
            let frame = NSRect(x: x, y: displayMaxY - y - height, width: width, height: height)
            let rawFrame = NSRect(x: x, y: y, width: width, height: height)
            return FloatingPanelTargetWindow(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                ownerBundleID: app?.bundleIdentifier,
                ownerName: ownerName,
                title: title,
                frame: frame,
                rawFrame: rawFrame
            )
        }
    }

    private func isLockCandidateWindow(layer: Int, ownerName: String, bundleID: String?) -> Bool {
        guard layer >= 0, layer <= 25 else {
            return false
        }
        let blockedBundles: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.loginwindow",
            "com.apple.notificationcenterui",
            "com.surteesstudios.Bartender"
        ]
        if let bundleID, blockedBundles.contains(bundleID) {
            return false
        }
        let blockedNames: Set<String> = [
            "Window Server",
            "Menubar"
        ]
        return !blockedNames.contains(ownerName)
    }

    private func saveLockedOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: lockedOriginXKey)
        defaults.set(Double(origin.y), forKey: lockedOriginYKey)
    }

    private func savedLockedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: lockedOriginXKey) != nil,
              defaults.object(forKey: lockedOriginYKey) != nil else {
            return nil
        }
        return NSPoint(x: defaults.double(forKey: lockedOriginXKey), y: defaults.double(forKey: lockedOriginYKey))
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
    let onClose: () -> Void

    var body: some View {
        let unreadCount = taskCompletionMonitor.unreadCompletedTaskCount
        let unreadEffect = FloatingPanelUnreadEffect(rawValue: floatingPanelUnreadEffect) ?? .ripple
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
            if unreadCount > 0, unreadEffect != .off {
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
                onClose: onClose,
                lockState: isLocked ? .locked : .unlocked,
                lockTargetDescription: lockTargetDescription,
                onToggleLock: onToggleLock
            )
                .environment(\.tokenDisplayScale, scale)
                .padding(.horizontal, FloatingTokenPanelMetrics.horizontalPadding * scale)
                .padding(.vertical, FloatingTokenPanelMetrics.verticalPadding * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            FloatingUnreadCompletionDot(
                count: unreadCount,
                color: appearance.unreadIndicatorColor,
                strokeColor: appearance.unreadIndicatorStrokeColor,
                scale: scale,
                onClear: taskCompletionMonitor.markCompletedTasksSeen
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture {
            taskCompletionMonitor.markCompletedTasksSeen()
        }
        .animation(.easeInOut(duration: 0.18), value: unreadCount > 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func withLockTarget(_ description: String?) -> FloatingTokenPanelView {
        var copy = self
        copy.lockTargetDescription = description
        return copy
    }
}

private struct FloatingUnreadEffectOverlay: View {
    let effect: FloatingPanelUnreadEffect
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    var body: some View {
        switch effect {
        case .off:
            EmptyView()
        case .ripple:
            FloatingUnreadRippleOverlay(color: color, cornerRadius: cornerRadius, scale: scale)
        }
    }
}

private struct FloatingUnreadRippleOverlay: View {
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                drawPanelTint(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                drawCircularRippleReflections(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func drawPanelTint(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let pulse = (sin(time * 1.1) + 1) / 2
        let background = Path(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        context.fill(background, with: .color(color.opacity(0.020 + 0.014 * pulse)))
    }

    private func drawCircularRippleReflections(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        let cycle: TimeInterval = 3.25
        let activeWindow = 0.92

        var softContext = context
        softContext.addFilter(.blur(radius: max(0.9, 1.18 * scale)))

        let cyclePhase = (time / cycle).truncatingRemainder(dividingBy: 1)
        guard cyclePhase < activeWindow else { return }
        let phase = cyclePhase / activeWindow
        let fadeOut = smoothPulseFade(phase)

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(size.width, size.height) * 0.78
        let baseRadius = maxRadius * CGFloat(easeOutSine(phase))
        let waveAlpha = fadeOut * (1.04 - 0.26 * phase)
        let rings: [(offset: CGFloat, alpha: Double, thickness: CGFloat)] = [
            (0, 1.00, 2.40),
            (-8.0 * scale, 0.55, 1.75),
            (-16.0 * scale, 0.28, 1.30)
        ]
        let sources = rippleSources(size: size, center: center)

        for ring in rings {
            let radius = baseRadius + ring.offset
            guard radius > 1.4 * scale else { continue }
            let thickness = ring.thickness * scale

            for source in sources {
                let arrival = source.arrivalDistance
                let reflectionFade = source.kind == .direct
                    ? 1
                    : Double(smoothStep((radius - arrival) / max(12 * scale, 1)))
                guard reflectionFade > 0.01 else { continue }
                let alpha = waveAlpha * ring.alpha * source.strength * reflectionFade
                drawCircularRing(
                    in: &context,
                    softContext: &softContext,
                    center: source.point,
                    radius: radius,
                    thickness: thickness,
                    alpha: alpha
                )
            }
        }

        drawEdgeContact(
            in: &context,
            size: size,
            center: center,
            radius: baseRadius,
            intensity: CGFloat(waveAlpha)
        )
    }

    private enum RippleSourceKind {
        case direct
        case reflection
        case cornerReflection
    }

    private struct RippleSource {
        let point: CGPoint
        let arrivalDistance: CGFloat
        let strength: Double
        let kind: RippleSourceKind
    }

    private func rippleSources(size: CGSize, center: CGPoint) -> [RippleSource] {
        [
            RippleSource(
                point: center,
                arrivalDistance: 0,
                strength: 1.0,
                kind: .direct
            ),
            RippleSource(
                point: CGPoint(x: center.x, y: -center.y),
                arrivalDistance: center.y,
                strength: 0.84,
                kind: .reflection
            ),
            RippleSource(
                point: CGPoint(x: center.x, y: size.height + (size.height - center.y)),
                arrivalDistance: size.height - center.y,
                strength: 0.84,
                kind: .reflection
            ),
            RippleSource(
                point: CGPoint(x: -center.x, y: center.y),
                arrivalDistance: center.x,
                strength: 0.66,
                kind: .reflection
            ),
            RippleSource(
                point: CGPoint(x: size.width + (size.width - center.x), y: center.y),
                arrivalDistance: size.width - center.x,
                strength: 0.66,
                kind: .reflection
            ),
            RippleSource(
                point: CGPoint(x: -center.x, y: -center.y),
                arrivalDistance: hypot(center.x, center.y),
                strength: 0.36,
                kind: .cornerReflection
            ),
            RippleSource(
                point: CGPoint(x: size.width + (size.width - center.x), y: -center.y),
                arrivalDistance: hypot(size.width - center.x, center.y),
                strength: 0.36,
                kind: .cornerReflection
            ),
            RippleSource(
                point: CGPoint(x: -center.x, y: size.height + (size.height - center.y)),
                arrivalDistance: hypot(center.x, size.height - center.y),
                strength: 0.36,
                kind: .cornerReflection
            ),
            RippleSource(
                point: CGPoint(x: size.width + (size.width - center.x), y: size.height + (size.height - center.y)),
                arrivalDistance: hypot(size.width - center.x, size.height - center.y),
                strength: 0.36,
                kind: .cornerReflection
            )
        ]
    }

    private func drawCircularRing(
        in context: inout GraphicsContext,
        softContext: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        thickness: CGFloat,
        alpha: Double
    ) {
        let band = circularRingBandPath(center: center, radius: radius, thickness: thickness)
        softContext.fill(
            band,
            with: .color(color.opacity(alpha * 0.54)),
            style: FillStyle(eoFill: true)
        )
        context.stroke(
            circlePath(center: center, radius: radius),
            with: .color(Color.white.opacity(alpha * 0.17)),
            lineWidth: max(0.18, 0.24 * scale)
        )
    }

    private func circularRingBandPath(center: CGPoint, radius: CGFloat, thickness: CGFloat) -> Path {
        let outerRadius = max(radius + thickness / 2, 0.2)
        let innerRadius = max(radius - thickness / 2, 0.1)
        var path = circlePath(center: center, radius: outerRadius)
        path.addPath(circlePath(center: center, radius: innerRadius))
        return path
    }

    private func circlePath(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    private func drawEdgeContact(
        in context: inout GraphicsContext,
        size: CGSize,
        center: CGPoint,
        radius: CGFloat,
        intensity: CGFloat
    ) {
        let top = gaussian(Double(radius), center: Double(center.y), width: Double(6.4 * scale))
        let bottom = gaussian(Double(radius), center: Double(size.height - center.y), width: Double(6.4 * scale))
        let left = gaussian(Double(radius), center: Double(center.x), width: Double(9.0 * scale))
        let right = gaussian(Double(radius), center: Double(size.width - center.x), width: Double(9.0 * scale))
        drawEdgeGlow(in: &context, rect: CGRect(x: 0, y: 0, width: size.width, height: 2.35 * scale), amount: top * Double(intensity))
        drawEdgeGlow(in: &context, rect: CGRect(x: 0, y: size.height - 2.35 * scale, width: size.width, height: 2.35 * scale), amount: bottom * Double(intensity))
        drawEdgeGlow(in: &context, rect: CGRect(x: 0, y: 0, width: 2.35 * scale, height: size.height), amount: left * Double(intensity))
        drawEdgeGlow(in: &context, rect: CGRect(x: size.width - 2.35 * scale, y: 0, width: 2.35 * scale, height: size.height), amount: right * Double(intensity))
    }

    private func drawEdgeGlow(in context: inout GraphicsContext, rect: CGRect, amount: Double) {
        guard amount > 0.02 else { return }
        context.fill(
            Path(roundedRect: rect, cornerSize: CGSize(width: 1.4 * scale, height: 1.4 * scale)),
            with: .color(Color.white.opacity(amount * 0.27))
        )
    }

    private func easeOutSine(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return sin(clamped * .pi / 2)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func smoothPulseFade(_ value: Double) -> Double {
        let fadeStart = 0.80
        guard value > fadeStart else { return 1 }
        let t = min(max((value - fadeStart) / (1 - fadeStart), 0), 1)
        return Double(1 - smoothStep(CGFloat(t)))
    }

    private func gaussian(_ value: Double, center: Double, width: Double) -> Double {
        let distance = (value - center) / max(width, 0.0001)
        return exp(-(distance * distance))
    }
}

private struct FloatingUnreadCompletionDot: View {
    let count: Int
    let color: Color
    let strokeColor: Color
    let scale: CGFloat
    let onClear: () -> Void

    var body: some View {
        if count > 0 {
            Button(action: onClear) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.54),
                                    color.opacity(0.56),
                                    color.opacity(0.90)
                                ],
                                center: UnitPoint(x: 0.30, y: 0.25),
                                startRadius: 0.3 * scale,
                                endRadius: 5.6 * scale
                            )
                        )
                    Circle()
                        .fill(color.opacity(0.22))
                        .blur(radius: 0.8 * scale)
                        .padding(0.7 * scale)
                    Circle()
                        .stroke(strokeColor, lineWidth: max(0.45, 0.55 * scale))
                    Circle()
                        .stroke(color.opacity(0.32), lineWidth: max(0.35, 0.45 * scale))
                        .padding(0.9 * scale)
                    Circle()
                        .fill(Color.white.opacity(0.42))
                        .frame(width: 1.35 * scale, height: 1.35 * scale)
                        .offset(x: -1.15 * scale, y: -1.15 * scale)
                }
                .frame(width: 5.2 * scale, height: 5.2 * scale)
                .frame(width: 18 * scale, height: 18 * scale, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8 * scale)
            .padding(.top, 4 * scale)
            .help(count == 1 ? "有 1 个完成任务未点开" : "有 \(count) 个完成任务未点开")
        }
    }
}

private struct FloatingPanelTargetWindow {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String
    let title: String
    let frame: NSRect
    let rawFrame: NSRect

    var displayName: String {
        if !title.isEmpty, title != ownerName {
            return "\(ownerName) · \(title)"
        }
        return ownerName.isEmpty ? "目标窗口" : ownerName
    }
}

private struct FloatingPanelWindowAnchor {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerBundleID: String?
    let windowTitle: String
    let targetDescription: String
    let offset: NSPoint
}

private enum FloatingPanelScreenGeometry {
    static var displayMaxY: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
    }
}

@MainActor
private func resizePanel(_ panel: NSPanel, scale: Double) {
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
private func anchoredPanelFrame(for panel: NSPanel, size: NSSize, topLeft: NSPoint) -> NSRect {
    let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)

    if let screenFrame {
        let margin: CGFloat = 8
        origin.x = min(max(origin.x, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        origin.y = min(max(origin.y, screenFrame.minY + margin), screenFrame.maxY - size.height - margin)
    }

    return NSRect(origin: origin, size: size)
}
