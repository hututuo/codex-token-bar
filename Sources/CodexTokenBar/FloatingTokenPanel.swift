import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

@MainActor
final class FloatingPanelEventSourceLifecycle {
    private let install: () -> Void
    private let remove: () -> Void
    private(set) var isActive = false

    init(install: @escaping () -> Void, remove: @escaping () -> Void) {
        self.install = install
        self.remove = remove
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        install()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        remove()
    }
}

enum FloatingPanelExternalEventRelevance {
    static func shouldRecordClick(isPresented: Bool) -> Bool {
        isPresented
    }

    static func shouldInspectWindow(
        isPresented: Bool,
        isLocked: Bool,
        hasLockedAnchor: Bool,
        hasActiveDrag: Bool
    ) -> Bool {
        isPresented && (isLocked || hasLockedAnchor || hasActiveDrag)
    }
}

enum FloatingPanelMouseDownAction: Equatable {
    case passThrough
    case dragPanel
    case openDashboard
}

@MainActor
final class FloatingTokenPanelWindow: NSPanel {
    var allowsBackgroundDrag = true
    var controlExclusionSize: CGFloat = 52
    var onOpenDashboard: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        configureInteractionIsolation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FloatingTokenPanelWindow does not support coder initialization")
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown else {
            super.sendEvent(event)
            return
        }

        switch mouseDownAction(clickCount: event.clickCount, location: event.locationInWindow) {
        case .openDashboard:
            onOpenDashboard?()
        case .dragPanel:
            performDrag(with: event)
        case .passThrough:
            super.sendEvent(event)
        }
    }

    func mouseDownAction(clickCount: Int, location: NSPoint) -> FloatingPanelMouseDownAction {
        guard !isInControlCorner(location) else { return .passThrough }
        if clickCount == 2 {
            return .openDashboard
        }
        if clickCount == 1, allowsBackgroundDrag {
            return .dragPanel
        }
        return .passThrough
    }

    private func configureInteractionIsolation() {
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        isMovableByWindowBackground = false
    }

    private func isInControlCorner(_ location: NSPoint) -> Bool {
        let bounds = contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        let size = min(max(controlExclusionSize, 0), bounds.width / 2)
        guard size > 0 else { return false }
        // The full left/right gutters are interactive. Besides the existing
        // lock/close buttons, paged rows place their subtle navigation arrows
        // here; the center remains a large uninterrupted drag surface.
        return location.x <= bounds.minX + size || location.x >= bounds.maxX - size
    }
}

@MainActor
final class FloatingTokenPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    @Published var lockTargetDescription: String?

    private static weak var activeController: FloatingTokenPanelController?
    private static let panelIdentifier = NSUserInterfaceItemIdentifier("CodexTokenBarFloatingTokenPanel")

    var panel: NSPanel?
    private var onClose: (() -> Void)?
    private var onToggleLock: (() -> Void)?
    private var onOpenDashboard: (() -> Void)?
    var lastExternalActivePID: pid_t?
    var lastExternalClickLocation: NSPoint?
    var lastExternalClickAt: Date?
    var lastExternalClickWindowNumber: Int?
    var lastExternalClickOwnerPID: pid_t?
    var lastExternalClickAXWindow: AXUIElement?
    var lastExternalClickAccessibilityTarget: FloatingPanelAccessibilityTarget?
    var externalMouseButtonIsDown = false
    var externalClickResolutionGeneration: UInt64 = 0
    var lockedAnchor: FloatingPanelWindowAnchor?
    var accessibilityResolver = FloatingPanelAccessibilityResolver()
    var followResolutionGeneration: UInt64 = 0
    var followFrameResolutionInFlight = false
    var anchorAccessibilityResolutionInFlight = false
    var cachedFollowAccessibilityFrame: FloatingPanelAccessibilityFrameCache?
    var followTimer: Timer?
    var followTimerInterval: TimeInterval?
    var fastFollowUntil: Date?
    var accessibilityObserverResolver = FloatingPanelAccessibilityObserverResolver()
    var accessibilityObserverGeneration: UInt64 = 0
    var accessibilityObserverRegistration: FloatingPanelAccessibilityObserverRegistration?
    var activeLockedTargetDrag: FloatingPanelLockedTargetDrag?
    var pendingLockedOriginToPersist: NSPoint?
    var lockedOriginPersistTimer: Timer?
    var lastLockedOriginPersistAt = Date.distantPast
    var strictVisibleWindowCache: FloatingPanelWindowListCache?
    var relaxedVisibleWindowCache: FloatingPanelWindowListCache?
    nonisolated(unsafe) private var globalMouseMonitor: Any?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    var externalClickAccessibilityTargetProvider: ((NSPoint) -> FloatingPanelAccessibilityTarget?)?
    var externalClickVisibleWindowsProvider: (() -> [FloatingPanelTargetWindow])?
    var externalEventStateProvider: (() -> (isPresented: Bool, isLocked: Bool))?
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
    private lazy var eventSourceLifecycle = FloatingPanelEventSourceLifecycle(
        install: { [weak self] in self?.installEventSources() },
        remove: { [weak self] in self?.removeEventSources() }
    )

    override init() {
        super.init()
        lastExternalActivePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func installEventSources() {
        guard globalMouseMonitor == nil, activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processIdentifier = app.processIdentifier
            Task { @MainActor in
                self?.activeApplicationDidChange(processIdentifier: processIdentifier)
            }
        }
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

    private func removeEventSources() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    deinit {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let registration = accessibilityObserverRegistration {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(registration.observer),
                .commonModes
            )
            accessibilityObserverResolver.remove(registration)
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
        eventSourceLifecycle.deactivate()
        invalidateExternalAccessibilityResolution()
        stopFollowingAnchor()
        let existingPanel = panel
        panel = nil
        onClose = nil
        onToggleLock = nil
        onOpenDashboard = nil
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
        radar: CodexRadarStore,
        taskCompletionMonitor: TaskCompletionMonitor,
        scale: FloatingTokenPanelScale,
        visibility: FloatingPanelContentVisibility,
        isLocked: Bool,
        onOpenDashboard: @escaping () -> Void,
        onToggleLock: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        Self.claimActiveController(self)
        self.onClose = onClose
        self.onToggleLock = onToggleLock
        self.onOpenDashboard = onOpenDashboard
        let layout = FloatingTokenPanelLayout(scale: scale, visibility: visibility)

        if panel == nil {
            let hostingController = NSHostingController(
                rootView: FloatingTokenPanelView(
                    store: store,
                    monitor: monitor,
                    quota: quota,
                    radar: radar,
                    taskCompletionMonitor: taskCompletionMonitor,
                    layout: layout,
                    visibility: visibility,
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
            let initialSize = layout.size
            hostingController.view.frame = NSRect(origin: .zero, size: initialSize)
            hostingController.view.autoresizingMask = [.width, .height]

            let panel = FloatingTokenPanelWindow(
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
            panel.allowsBackgroundDrag = !isLocked
            panel.controlExclusionSize = 52 * layout.effectiveScale
            panel.onOpenDashboard = { [weak self] in
                self?.onOpenDashboard?()
            }
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.delegate = self
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = layout.cornerRadius
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
            position(panel)
            self.panel = panel
        }
        Self.closeStrayPanels(except: panel)

        if let panel = panel as? FloatingTokenPanelWindow {
            panel.allowsBackgroundDrag = !isLocked
            panel.controlExclusionSize = 52 * layout.effectiveScale
            panel.onOpenDashboard = { [weak self] in
                self?.onOpenDashboard?()
            }
        }

        if let hostingController = panel?.contentViewController as? NSHostingController<FloatingTokenPanelView> {
            hostingController.rootView = FloatingTokenPanelView(
                store: store,
                monitor: monitor,
                quota: quota,
                radar: radar,
                taskCompletionMonitor: taskCompletionMonitor,
                layout: layout,
                visibility: visibility,
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
        updateSize(layout: layout)
        updateLockState(isLocked, force: !wasPresented)
        panel?.orderFrontRegardless()
        isPresented = true
        eventSourceLifecycle.activate()
    }

    func updateSize(layout: FloatingTokenPanelLayout) {
        guard let panel else { return }
        isProgrammaticPanelMove = true
        resizePanel(panel, layout: layout)
        panel.contentView?.layer?.cornerRadius = layout.cornerRadius
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
        eventSourceLifecycle.deactivate()
        stopFollowingAnchor()
        onClose = nil
        onToggleLock = nil
        onOpenDashboard = nil
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

    private func activeApplicationDidChange(processIdentifier: pid_t) {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalActivePID = processIdentifier
    }


}

struct FloatingTokenPanelView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var radar: CodexRadarStore
    @ObservedObject var taskCompletionMonitor: TaskCompletionMonitor
    let layout: FloatingTokenPanelLayout
    let visibility: FloatingPanelContentVisibility
    let isLocked: Bool
    var lockTargetDescription: String?
    let onToggleLock: () -> Void
    @AppStorage("floatingPanelOpacity") private var floatingPanelOpacity = 0.88
    @AppStorage(FloatingPanelAppearance.startHexKey) private var floatingPanelGradientStartHex = FloatingPanelAppearance.defaultStartHex
    @AppStorage(FloatingPanelAppearance.endHexKey) private var floatingPanelGradientEndHex = FloatingPanelAppearance.defaultEndHex
    @AppStorage(FloatingPanelAppearance.directionKey) private var floatingPanelGradientDirection = FloatingPanelAppearance.defaultDirection
    @AppStorage(FloatingPanelAppearance.styleKey) private var floatingPanelGradientStyle = FloatingPanelAppearance.defaultStyle
    @AppStorage(FloatingQuotaColorStyle.modeKey) private var floatingQuotaColorMode = FloatingQuotaColorStyle.defaultMode
    @AppStorage(FloatingQuotaColorStyle.fixedHexKey) private var floatingQuotaFixedHex = FloatingQuotaColorStyle.defaultFixedHex
    @AppStorage(FloatingPanelAppearance.unreadEffectKey) private var floatingPanelUnreadEffect = FloatingPanelAppearance.defaultUnreadEffect
    @AppStorage(FloatingPanelAppearance.unreadPreviewUntilKey) private var floatingPanelUnreadPreviewUntil = 0.0
    @AppStorage(FloatingPanelAppearance.textWhiteOverrideKey) private var floatingPanelTextWhiteOverride = FloatingPanelAppearance.defaultTextWhiteOverride
    @AppStorage("setupGuideCompletedV01") private var setupGuideCompleted = false
    @AppStorage(FloatingPanelContentVisibility.pagingGuideRevisionKey) private var pagingGuideRevision = 0
    @AppStorage(FloatingPanelContentVisibility.pageNavigationArrowsKey) private var persistedPageNavigationArrows = FloatingPanelContentVisibility.default.showPageNavigationArrows
    @State private var pagingGuideShowsArrowGlyphs = false
    let onClose: () -> Void

    var body: some View {
        let unreadCount = taskCompletionMonitor.unreadThreadCount
        let unreadEffect = FloatingPanelUnreadEffect(rawValue: floatingPanelUnreadEffect) ?? .ripple
        let isPreviewingUnreadEffect = unreadCount == 0
            && unreadEffect != .off
            && floatingPanelUnreadPreviewUntil > Date.timeIntervalSinceReferenceDate
        let shouldShowUnreadEffect = unreadEffect != .off && (unreadCount > 0 || isPreviewingUnreadEffect)
        let scale = layout.effectiveScale
        let size = layout.size
        let cornerRadius = layout.cornerRadius
        let appearance = FloatingPanelAppearance(
            startHex: floatingPanelGradientStartHex,
            endHex: floatingPanelGradientEndHex,
            directionRaw: floatingPanelGradientDirection,
            styleRaw: floatingPanelGradientStyle
        )
        let quotaColorStyle = FloatingQuotaColorStyle(
            modeRaw: floatingQuotaColorMode,
            fixedHex: floatingQuotaFixedHex,
            gradientAppearance: appearance
        )
        let displaySnapshot = TokenDisplaySnapshot.make(
            store: store,
            monitor: monitor,
            quota: quota,
            runningThreads: taskCompletionMonitor.runningThreadSummary
        )
        let textTone = FloatingPanelTextTonePreference.mode(for: floatingPanelTextWhiteOverride)
        let automaticTextPalettes = appearance.textPalettes(
            panelSize: size,
            scale: scale,
            opacity: floatingPanelOpacity,
            automaticStrength: textTone.automaticStrength,
            visibility: visibility,
            hasPreciseTokenUsage: displaySnapshot.hasPreciseTokenUsage
        )
        let overridePalette = textTone.manualWhite.map(FloatingPanelReadableTextPalette.init(fixedWhite:))
        let baseTextPalette = overridePalette ?? automaticTextPalettes.controlPalette
        let rowTextPalettes = overridePalette.map { palette in
            Dictionary(uniqueKeysWithValues: FloatingPanelContentGroup.allCases.map { ($0, palette) })
        } ?? automaticTextPalettes.rowPalettes
        let metricTextPalettes = overridePalette.map { palette in
            Dictionary(uniqueKeysWithValues: FloatingPanelMetricTextRegion.allCases.map { ($0, palette) })
        } ?? automaticTextPalettes.metricPalettes
        let embeddedUsageStatusTextPalette = overridePalette ?? automaticTextPalettes.embeddedUsageStatusPalette
        let standaloneUsageStatusTextPalette = overridePalette ?? automaticTextPalettes.standaloneUsageStatusPalette
        let radarActionTextPalette = overridePalette ?? automaticTextPalettes.radarActionPalette
        let radarModelTextPalette = overridePalette ?? automaticTextPalettes.radarModelPalette
        let pagingGuidePresented = FloatingPanelPagingGuideState.shouldPresent(
            setupGuideCompleted: setupGuideCompleted,
            completedRevision: pagingGuideRevision,
            hasPagedRows: visibility.layoutRows.contains(where: \.isPaged)
        )
        var presentedVisibility = visibility
        presentedVisibility.showPageNavigationArrows = pagingGuidePresented
            ? pagingGuideShowsArrowGlyphs
            : persistedPageNavigationArrows
        let pagingGuideTargetY = FloatingTokenPanelMetrics.firstPagedRowCenterY(
            visibility: visibility,
            panelHeight: size.height,
            scale: scale
        ) ?? size.height / 2
        let pageNavigationAction: (() -> Void)? = pagingGuidePresented
            ? { completePagingGuide() }
            : nil

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
                snapshot: displaySnapshot,
                radarSnapshot: radar.snapshot,
                radarPresentation: CodexRadarPresentationState(
                    snapshot: radar.snapshot,
                    status: radar.status,
                    diagnostics: radar.diagnostics,
                    staleDataDisplayed: radar.staleDataDisplayed,
                    feedStaleDataDisplayed: radar.feedStaleDataDisplayed,
                    crowdSnapshot: radar.crowdSnapshot
                ),
                visibility: presentedVisibility,
                onClose: nil,
                lockState: nil,
                lockTargetDescription: nil,
                onToggleLock: nil,
                onPageNavigation: pageNavigationAction
            )
                .environment(\.tokenDisplayScale, scale)
                .padding(.vertical, FloatingTokenPanelMetrics.verticalPadding * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .zIndex(2)

            if pagingGuidePresented {
                FloatingPanelPagingGuide(
                    showsArrowGlyphs: Binding(
                        get: { pagingGuideShowsArrowGlyphs },
                        set: { value in
                            pagingGuideShowsArrowGlyphs = value
                            persistedPageNavigationArrows = value
                        }
                    ),
                    scale: scale,
                    targetY: pagingGuideTargetY,
                    onComplete: completePagingGuide
                )
                .zIndex(6)
            }

            FloatingPanelLockButton(
                state: isLocked ? .locked : .unlocked,
                targetDescription: lockTargetDescription,
                scale: scale,
                action: onToggleLock
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zIndex(8)

            FloatingPanelCloseButton(
                scale: scale,
                action: onClose
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(8)
        }
        .background(
            FloatingPanelInteractionBridge(
                guidePresented: pagingGuidePresented,
                isLocked: isLocked
            )
        )
        .environment(\.tokenDisplayTextPalette, baseTextPalette)
        .environment(\.tokenDisplayRowTextPalettes, rowTextPalettes)
        .environment(\.tokenDisplayMetricTextPalettes, metricTextPalettes)
        .environment(\.tokenDisplayQuotaColorStyle, quotaColorStyle)
        .environment(\.tokenDisplayEmbeddedUsageStatusTextPalette, embeddedUsageStatusTextPalette)
        .environment(\.tokenDisplayStandaloneUsageStatusTextPalette, standaloneUsageStatusTextPalette)
        .environment(\.tokenDisplayRadarActionTextPalette, radarActionTextPalette)
        .environment(\.tokenDisplayRadarModelTextPalette, radarModelTextPalette)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: unreadCount > 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func completePagingGuide() {
        persistedPageNavigationArrows = pagingGuideShowsArrowGlyphs
        pagingGuideRevision = FloatingPanelContentVisibility.currentPagingGuideRevision
    }

    func withLockTarget(_ description: String?) -> FloatingTokenPanelView {
        var copy = self
        copy.lockTargetDescription = description
        return copy
    }
}

@MainActor
func resizePanel(_ panel: NSPanel, layout: FloatingTokenPanelLayout) {
    let previousFrame = panel.frame
    let topLeft = NSPoint(x: previousFrame.minX, y: previousFrame.maxY)
    let targetSize = layout.size
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
