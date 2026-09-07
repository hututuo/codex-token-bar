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

enum FloatingRunningModelDetailsDismissalPolicy {
    static func shouldDismissForExternalClick(
        isPresented: Bool,
        panelFrame: NSRect?,
        location: NSPoint
    ) -> Bool {
        guard isPresented else { return false }
        return panelFrame.map { !$0.contains(location) } ?? true
    }

    static func shouldDismissForWindowClick(
        isPresented: Bool,
        detailsFrame: NSRect,
        triggerFrames: [NSRect],
        location: NSPoint
    ) -> Bool {
        guard isPresented, !detailsFrame.contains(location) else { return false }
        return !triggerFrames.contains(where: { $0.contains(location) })
    }
}

@MainActor
final class FloatingRunningModelDetailsSessionState: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var drawerLayout: FloatingTokenPanelLayout?

    func updateLayout(_ value: FloatingTokenPanelLayout?) {
        guard drawerLayout != value else { return }
        if value == nil {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { drawerLayout = nil }
        } else {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) {
                drawerLayout = value
            }
        }
    }

    func toggle() {
        if isPresented { dismiss(); return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) {
            isPresented.toggle()
        }
    }

    func dismiss() {
        guard isPresented else { return }
        // Geometry closes atomically with the native window. Animating this
        // layout would interpolate the main card after its window already moved.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresented = false }
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
    var suppressesBackgroundMouseActions = false
    var controlExclusionSize: CGFloat = 52
    var interactiveControlFrames: [NSRect] = []
    var runningModelDetailsPresented = false
    var runningModelDetailsFrame = NSRect.zero
    var onOpenDashboard: (() -> Void)?
    var onDismissRunningModelDetails: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onInteractionEnded: (() -> Void)?

    override var canBecomeKey: Bool { runningModelDetailsPresented }
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
        if event.type == .keyDown, event.keyCode == 53, runningModelDetailsPresented {
            onDismissRunningModelDetails?()
            return
        }
        if event.type == .leftMouseUp || event.type == .rightMouseUp { onInteractionEnded?() }
        guard event.type == .leftMouseDown else {
            super.sendEvent(event)
            return
        }

        if FloatingRunningModelDetailsDismissalPolicy.shouldDismissForWindowClick(
            isPresented: runningModelDetailsPresented,
            detailsFrame: runningModelDetailsFrame,
            triggerFrames: interactiveControlFrames,
            location: event.locationInWindow
        ) {
            onDismissRunningModelDetails?()
            super.sendEvent(event)
            return
        }

        switch mouseDownAction(clickCount: event.clickCount, location: event.locationInWindow) {
        case .openDashboard:
            onOpenDashboard?()
        case .dragPanel:
            onDragBegan?()
            performDrag(with: event)
            onDragEnded?()
        case .passThrough:
            super.sendEvent(event)
        }
    }

    func mouseDownAction(clickCount: Int, location: NSPoint) -> FloatingPanelMouseDownAction {
        guard !suppressesBackgroundMouseActions else { return .passThrough }
        guard !interactiveControlFrames.contains(where: { $0.contains(location) }) else {
            return .passThrough
        }
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
    let edgeDock = FloatingEdgeDockController()
    private var onClose: (() -> Void)?
    private var onToggleLock: (() -> Void)?
    private var onOpenDashboard: (() -> Void)?
    private let pagingGuideSessionState = FloatingPanelPagingGuideSessionState()
    private let runningModelDetailsSessionState = FloatingRunningModelDetailsSessionState()
    private var lastPanelScale: FloatingTokenPanelScale?
    private var lastPanelVisibility: FloatingPanelContentVisibility?
    var lastPagingGuidePresented = false
    var lastRunningModelDetailsPresented = false
    private var lastRunningModelDetailsRowUnits = 0
    var runningModelDetailsPlacement: FloatingRunningModelDetailsPlacement = .below
    var runningModelDetailsBaseFrame: NSRect?
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
        edgeDock.dispose()
        let existingPanel = panel
        panel = nil
        onClose = nil
        onToggleLock = nil
        onOpenDashboard = nil
        isPresented = false
        appliedLockState = false
        lastRunningModelDetailsPresented = false
        runningModelDetailsSessionState.dismiss()
        runningModelDetailsBaseFrame = nil
        runningModelDetailsPlacement = .below

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
        let pagingGuidePresented = shouldPresentPagingGuide(visibility: visibility)
        let runningModelDetailsRowUnits = taskCompletionMonitor
            .runningThreadSummary
            .runningModelDetailsRowUnits
        let layout = FloatingTokenPanelLayout(
            scale: scale,
            visibility: visibility,
            pagingGuidePresented: pagingGuidePresented,
            runningModelDetailsPresented: !pagingGuidePresented && lastRunningModelDetailsPresented,
            runningModelDetailsRowUnits: runningModelDetailsRowUnits,
            runningModelDetailsPlacement: runningModelDetailsPlacement
        )
        lastPanelScale = scale
        lastPanelVisibility = visibility
        lastPagingGuidePresented = pagingGuidePresented
        lastRunningModelDetailsRowUnits = runningModelDetailsRowUnits

        if panel == nil {
            let hostingController = NSHostingController(
                rootView: FloatingTokenPanelView(
                    store: store,
                    monitor: monitor,
                    quota: quota,
                    radar: radar,
                    taskCompletionMonitor: taskCompletionMonitor,
                    layout: layout,
                    edgeDockPresentation: edgeDock.presentation,
                    visibility: visibility,
                    isLocked: isLocked,
                    lockTargetDescription: lockTargetDescription,
                    pagingGuideSessionState: pagingGuideSessionState,
                    runningModelDetailsSessionState: runningModelDetailsSessionState,
                    onPagingGuidePresentationChanged: { [weak self] presented in
                        self?.setPagingGuidePresented(presented)
                    },
                    onRunningModelDetailsPresentationChanged: { [weak self] presented in
                        self?.setRunningModelDetailsPresented(presented)
                    },
                    onRunningModelDetailsRowUnitsChanged: { [weak self] rowUnits in
                        self?.setRunningModelDetailsRowUnits(rowUnits)
                    },
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
            panel.suppressesBackgroundMouseActions = pagingGuidePresented || lastRunningModelDetailsPresented
            panel.controlExclusionSize = 52 * layout.effectiveScale
            panel.onOpenDashboard = { [weak self] in
                self?.onOpenDashboard?()
            }
            panel.onDismissRunningModelDetails = { [weak self] in
                self?.dismissRunningModelDetails()
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
            edgeDock.bind(panel: panel, enabled: { [weak self] in
                guard let self else { return false }
                return self.isPresented && !self.appliedLockState
                    && !self.lastPagingGuidePresented
            }, persist: { [weak self] origin in self?.saveLockedOrigin(origin) })
            panel.onDragBegan = { [weak self] in self?.edgeDock.beginDrag() }
            panel.onDragEnded = { [weak self] in self?.edgeDock.endDrag() }
            panel.onInteractionEnded = { [weak self] in self?.edgeDock.interactionEnded() }
        }
        Self.closeStrayPanels(except: panel)

        if let panel = panel as? FloatingTokenPanelWindow {
            panel.allowsBackgroundDrag = !isLocked
            panel.suppressesBackgroundMouseActions = pagingGuidePresented || lastRunningModelDetailsPresented
            panel.controlExclusionSize = 52 * layout.effectiveScale
            panel.onOpenDashboard = { [weak self] in
                self?.onOpenDashboard?()
            }
            panel.onDismissRunningModelDetails = { [weak self] in
                self?.dismissRunningModelDetails()
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
                edgeDockPresentation: edgeDock.presentation,
                visibility: visibility,
                isLocked: isLocked,
                lockTargetDescription: lockTargetDescription,
                pagingGuideSessionState: pagingGuideSessionState,
                runningModelDetailsSessionState: runningModelDetailsSessionState,
                onPagingGuidePresentationChanged: { [weak self] presented in
                    self?.setPagingGuidePresented(presented)
                },
                onRunningModelDetailsPresentationChanged: { [weak self] presented in
                    self?.setRunningModelDetailsPresented(presented)
                },
                onRunningModelDetailsRowUnitsChanged: { [weak self] rowUnits in
                    self?.setRunningModelDetailsRowUnits(rowUnits)
                },
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
        edgeDock.snapIfNearEdge()
    }

    private func shouldPresentPagingGuide(
        visibility: FloatingPanelContentVisibility
    ) -> Bool {
        let revision = FloatingPanelContentVisibility.currentPagingGuideRevision
        return pagingGuideSessionState.completion(for: revision) == nil
            && FloatingPanelPagingGuideState.shouldPresent(
                setupGuideCompleted: UserDefaults.standard.bool(
                    forKey: FloatingPanelPagingGuideState.setupGuideCompletedKey
                ),
                completedRevision: UserDefaults.standard.integer(
                    forKey: FloatingPanelContentVisibility.pagingGuideRevisionKey
                ),
                hasPagedRows: visibility.layoutRows.contains(where: \.isPaged),
                hasRunningThreadDetailsTarget: visibility.hasRunningThreadDetailsTarget
            )
    }

    private func setPagingGuidePresented(_ presented: Bool) {
        (panel as? FloatingTokenPanelWindow)?.suppressesBackgroundMouseActions = presented
            || lastRunningModelDetailsPresented
        guard presented != lastPagingGuidePresented,
              let lastPanelScale,
              let lastPanelVisibility else { return }
        lastPagingGuidePresented = presented
        updateSize(
            layout: FloatingTokenPanelLayout(
                scale: lastPanelScale,
                visibility: lastPanelVisibility,
                pagingGuidePresented: presented,
                runningModelDetailsPresented: !presented && lastRunningModelDetailsPresented,
                runningModelDetailsRowUnits: lastRunningModelDetailsRowUnits,
                runningModelDetailsPlacement: runningModelDetailsPlacement
            )
        )
    }

    private func setRunningModelDetailsPresented(_ presented: Bool) {
        guard presented != lastRunningModelDetailsPresented,
              let lastPanelScale,
              let lastPanelVisibility else { return }

        if presented, let panel {
            let surfaceSize = FloatingTokenPanelMetrics.size(
                effectiveScale: lastPanelScale.value,
                visibility: lastPanelVisibility
            )
            let expandedSize = FloatingTokenPanelMetrics.size(
                effectiveScale: lastPanelScale.value,
                visibility: lastPanelVisibility,
                runningModelDetailsPresented: true,
                runningModelDetailsRowUnits: lastRunningModelDetailsRowUnits
            )
            runningModelDetailsBaseFrame = FloatingTokenPanelResizePolicy.baseFrame(
                for: panel.frame,
                surfaceSize: surfaceSize,
                placement: runningModelDetailsPlacement
            )
            runningModelDetailsPlacement = FloatingTokenPanelResizePolicy.runningModelDetailsPlacement(
                panelFrame: runningModelDetailsBaseFrame ?? panel.frame,
                surfaceSize: surfaceSize,
                expandedSize: expandedSize,
                screenFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            )
        }
        edgeDock.holdOpen(presented)
        lastRunningModelDetailsPresented = presented
        (panel as? FloatingTokenPanelWindow)?.suppressesBackgroundMouseActions = presented
            || lastPagingGuidePresented
        updateSize(
            layout: FloatingTokenPanelLayout(
                scale: lastPanelScale,
                visibility: lastPanelVisibility,
                pagingGuidePresented: lastPagingGuidePresented,
                runningModelDetailsPresented: presented && !lastPagingGuidePresented,
                runningModelDetailsRowUnits: lastRunningModelDetailsRowUnits,
                runningModelDetailsPlacement: runningModelDetailsPlacement
            )
        )
        if presented { panel?.makeKey() }
        else {
            panel?.resignKey()
            runningModelDetailsBaseFrame = nil
            runningModelDetailsPlacement = .below
            runningModelDetailsSessionState.updateLayout(nil)
        }
    }

    private func setRunningModelDetailsRowUnits(_ rowUnits: Int) {
        let rowUnits = max(0, rowUnits)
        guard rowUnits != lastRunningModelDetailsRowUnits else { return }
        lastRunningModelDetailsRowUnits = rowUnits
        guard lastRunningModelDetailsPresented,
              !lastPagingGuidePresented,
              let lastPanelScale,
              let lastPanelVisibility else { return }
        updateSize(
            layout: FloatingTokenPanelLayout(
                scale: lastPanelScale,
                visibility: lastPanelVisibility,
                pagingGuidePresented: false,
                runningModelDetailsPresented: true,
                runningModelDetailsRowUnits: rowUnits,
                runningModelDetailsPlacement: runningModelDetailsPlacement
            )
        )
    }

    func dismissRunningModelDetails() {
        runningModelDetailsSessionState.dismiss()
        setRunningModelDetailsPresented(false)
    }

    var runningModelDetailsArePresented: Bool {
        lastRunningModelDetailsPresented
    }

    func updateSize(layout: FloatingTokenPanelLayout) {
        guard let panel else { return }
        var layout = layout
        if layout.runningModelDetailsPresented, let base = runningModelDetailsBaseFrame {
            layout.size.height = FloatingTokenPanelResizePolicy.constrainedHeight(
                baseFrame: base, expandedHeight: layout.size.height,
                screenFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, scale: layout.effectiveScale)
        }
        runningModelDetailsSessionState.updateLayout(layout.runningModelDetailsPresented ? layout : nil)
        if let fullFrame = edgeDock.expandedFrame, fullFrame.size == layout.size,
           !layout.runningModelDetailsPresented, !lastPagingGuidePresented, !appliedLockState {
            return
        }
        edgeDock.prepareForResize()
        let surfaceSize = lastPanelVisibility.map {
            FloatingTokenPanelMetrics.size(
                effectiveScale: layout.effectiveScale,
                visibility: $0
            )
        } ?? layout.size
        if layout.runningModelDetailsPresented, runningModelDetailsBaseFrame == nil {
            runningModelDetailsBaseFrame = FloatingTokenPanelResizePolicy.baseFrame(
                for: panel.frame,
                surfaceSize: surfaceSize,
                placement: layout.runningModelDetailsPlacement
            )
        }
        isProgrammaticPanelMove = true
        resizePanel(
            panel,
            layout: layout,
            surfaceSize: surfaceSize,
            baseFrame: runningModelDetailsBaseFrame
        )
        if let panel = panel as? FloatingTokenPanelWindow,
           let visibility = lastPanelVisibility {
            panel.interactiveControlFrames = runningThreadControlFrames(
                layout: layout,
                visibility: visibility
            )
            panel.runningModelDetailsPresented = lastRunningModelDetailsPresented
                && !lastPagingGuidePresented
            panel.runningModelDetailsFrame = panel.runningModelDetailsPresented
                ? runningModelDetailsCardFrame(layout: layout, surfaceSize: surfaceSize)
                : .zero
        }
        edgeDock.resumeAfterResize()
        panel.contentView?.layer?.cornerRadius = edgeDock.isAttached ? 0 : layout.cornerRadius

        saveLockedOrigin(
            persistedOrigin(
                for: panel,
                surfaceSize: surfaceSize,
                detailsPresented: layout.runningModelDetailsPresented
            )
        )
        refreshLockedAnchorOffsetForCurrentFrame()
        if !layout.runningModelDetailsPresented {
            runningModelDetailsBaseFrame = nil
            runningModelDetailsPlacement = .below
        }
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticPanelMove = false
            self?.edgeDock.resumeAfterResize()
        }
    }

    func close() {
        closePanel(destroy: true, unregisterActive: true)
    }

    func windowWillClose(_ notification: Notification) {
        edgeDock.dispose()
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
        guard !isProgrammaticPanelMove, !edgeDock.isApplyingGeometry else { return }
        if lastRunningModelDetailsPresented,
           let surfaceSize = currentRunningModelDetailsSurfaceSize() {
            runningModelDetailsBaseFrame = FloatingTokenPanelResizePolicy.baseFrame(
                for: panel.frame,
                surfaceSize: surfaceSize,
                placement: runningModelDetailsPlacement
            )
        }
        saveLockedOrigin(persistedOrigin(for: panel))
        if lockedAnchor != nil {
            lockedAnchor = currentAnchor(for: panel)
            lockTargetDescription = lockedAnchor?.targetDescription
            refreshFloatingPanelLockStatus()
        }
    }

    func currentRunningModelDetailsSurfaceSize() -> NSSize? {
        guard let lastPanelScale, let lastPanelVisibility else { return nil }
        return FloatingTokenPanelMetrics.size(
            effectiveScale: lastPanelScale.value,
            visibility: lastPanelVisibility
        )
    }

    func persistedOrigin(
        for panel: NSPanel,
        surfaceSize: NSSize? = nil,
        detailsPresented: Bool? = nil
    ) -> NSPoint {
        let detailsPresented = detailsPresented ?? (lastRunningModelDetailsPresented && !lastPagingGuidePresented)
        if detailsPresented, let base = runningModelDetailsBaseFrame { return base.origin }
        if let dockedFrame = edgeDock.expandedFrame { return dockedFrame.origin }
        guard detailsPresented,
              let surfaceSize = surfaceSize ?? currentRunningModelDetailsSurfaceSize()
        else {
            return panel.frame.origin
        }
        let baseFrame = FloatingTokenPanelResizePolicy.baseFrame(
            for: panel.frame,
            surfaceSize: surfaceSize,
            placement: runningModelDetailsPlacement
        )
        return baseFrame.origin
    }

    func frameForDesiredBaseOrigin(
        _ origin: NSPoint,
        panel: NSPanel,
        size: NSSize
    ) -> NSRect {
        guard lastRunningModelDetailsPresented && !lastPagingGuidePresented,
              let surfaceSize = currentRunningModelDetailsSurfaceSize()
        else {
            return anchoredPanelFrame(
                for: panel,
                size: size,
                topLeft: NSPoint(x: origin.x, y: origin.y + size.height)
            )
        }
        let baseFrame = NSRect(
            x: origin.x,
            y: origin.y,
            width: surfaceSize.width,
            height: surfaceSize.height
        )
        return FloatingTokenPanelResizePolicy.expandedFrame(
            baseFrame: baseFrame,
            expandedSize: size,
            surfaceSize: surfaceSize,
            placement: runningModelDetailsPlacement,
            screenFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
    }

    private func activeApplicationDidChange(processIdentifier: pid_t) {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        dismissRunningModelDetails()
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
    @ObservedObject var edgeDockPresentation: FloatingEdgeDockPresentation
    let visibility: FloatingPanelContentVisibility
    let isLocked: Bool
    var lockTargetDescription: String?
    @ObservedObject var pagingGuideSessionState: FloatingPanelPagingGuideSessionState
    @ObservedObject var runningModelDetailsSessionState: FloatingRunningModelDetailsSessionState
    let onPagingGuidePresentationChanged: (Bool) -> Void
    let onRunningModelDetailsPresentationChanged: (Bool) -> Void
    let onRunningModelDetailsRowUnitsChanged: (Int) -> Void
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
    @AppStorage(FloatingPanelPagingGuideState.setupGuideCompletedKey) private var setupGuideCompleted = false
    @AppStorage(FloatingPanelContentVisibility.pagingGuideRevisionKey) private var pagingGuideRevision = 0
    @AppStorage(FloatingPanelContentVisibility.pageNavigationArrowsKey) private var persistedPageNavigationArrows = FloatingPanelContentVisibility.default.showPageNavigationArrows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pagingGuideShowsArrowGlyphs = false
    @State private var pagingGuidePageIndex = 0
    let onClose: () -> Void

    var body: some View {
        let unreadCount = taskCompletionMonitor.unreadThreadCount
        let unreadEffect = FloatingPanelUnreadEffect(rawValue: floatingPanelUnreadEffect) ?? .ripple
        let isPreviewingUnreadEffect = unreadCount == 0
            && unreadEffect != .off
            && floatingPanelUnreadPreviewUntil > Date.timeIntervalSinceReferenceDate
        let shouldShowUnreadEffect = !edgeDockPresentation.collapsed && unreadEffect != .off && (unreadCount > 0 || isPreviewingUnreadEffect)
        let scale = layout.effectiveScale
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
        let liveRunningThreads = taskCompletionMonitor.runningThreadSummary
        let liveDisplaySnapshot = TokenDisplaySnapshot.make(
            store: store,
            monitor: monitor,
            quota: quota,
            runningThreads: liveRunningThreads
        )
        let textTone = FloatingPanelTextTonePreference.mode(for: floatingPanelTextWhiteOverride)
        let automaticTextPalettes = appearance.textPalettes(
            panelSize: FloatingTokenPanelMetrics.size(
                effectiveScale: scale,
                visibility: visibility,
                pagingGuidePresented: false
            ),
            scale: scale,
            opacity: floatingPanelOpacity,
            automaticStrength: textTone.automaticStrength,
            visibility: visibility,
            hasPreciseTokenUsage: liveDisplaySnapshot.hasPreciseTokenUsage
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
        let currentPagingGuideRevision = FloatingPanelContentVisibility.currentPagingGuideRevision
        let immediatePagingGuideCompletion = pagingGuideSessionState.completion(
            for: currentPagingGuideRevision
        )
        let pagingGuidePages = FloatingPanelPagingGuideState.pages(
            completedRevision: pagingGuideRevision,
            hasPagedRows: visibility.layoutRows.contains(where: \.isPaged),
            hasRunningThreadDetailsTarget: visibility.hasRunningThreadDetailsTarget
        )
        let pagingGuidePresented = immediatePagingGuideCompletion == nil
            && setupGuideCompleted
            && !pagingGuidePages.isEmpty
        let safePagingGuidePageIndex = min(
            max(pagingGuidePageIndex, 0),
            max(0, pagingGuidePages.count - 1)
        )
        let activePagingGuidePage = pagingGuidePages.indices.contains(safePagingGuidePageIndex)
            ? pagingGuidePages[safePagingGuidePageIndex]
            : .runningModels
        let presentedRunningThreads = FloatingPanelPagingGuideState.runningThreadSummary(
            live: liveRunningThreads,
            guidePresented: pagingGuidePresented,
            page: activePagingGuidePage
        )
        let displaySnapshot = presentedRunningThreads == liveRunningThreads
            ? liveDisplaySnapshot
            : TokenDisplaySnapshot.make(
                store: store,
                monitor: monitor,
                quota: quota,
                runningThreads: presentedRunningThreads
            )
        let effectiveRunningModelDetailsPresented = runningModelDetailsSessionState.isPresented
            && !pagingGuidePresented
            && visibility.hasRunningThreadDetailsTarget
        let measuredSize = FloatingTokenPanelMetrics.size(
            effectiveScale: scale,
            visibility: visibility,
            pagingGuidePresented: pagingGuidePresented,
            runningModelDetailsPresented: effectiveRunningModelDetailsPresented,
            runningModelDetailsRowUnits: displaySnapshot.runningThreads.runningModelDetailsRowUnits
        )
        let drawerLayout = runningModelDetailsSessionState.drawerLayout
        let size = effectiveRunningModelDetailsPresented ? drawerLayout?.size ?? measuredSize : measuredSize
        let detailsPlacement = drawerLayout?.runningModelDetailsPlacement ?? .below
        let surfaceSize = FloatingTokenPanelMetrics.size(
            effectiveScale: scale,
            visibility: visibility,
            pagingGuidePresented: false
        )
        let cornerRadius = FloatingTokenPanelMetrics.baseCornerRadius * scale
        let immediatelyAppliedArrowGlyphs = pagingGuideRevision < currentPagingGuideRevision
            ? immediatePagingGuideCompletion?.showsArrowGlyphs
            : nil
        var presentedVisibility = visibility
        presentedVisibility.showPageNavigationArrows = pagingGuidePresented
            ? pagingGuideShowsArrowGlyphs
            : (immediatelyAppliedArrowGlyphs ?? persistedPageNavigationArrows)
        let pagingGuideTargetYs = Array(FloatingTokenPanelMetrics.pagedRowCenterYs(
            visibility: visibility,
            panelHeight: surfaceSize.height,
            scale: scale
        ).prefix(2))
        let safePagingGuideTargetYs = pagingGuideTargetYs.isEmpty
            ? [surfaceSize.height / 2]
            : pagingGuideTargetYs
        let pagingGuideTargetY = safePagingGuideTargetYs[0]
        let pagingGuideCalloutY = max(
            6.scaled(by: scale),
            (FloatingTokenPanelMetrics.usageStatusRowCenterY(
                visibility: visibility,
                panelHeight: surfaceSize.height,
                scale: scale
            ) ?? surfaceSize.height / 2) - 5.scaled(by: scale)
        )
        // Keep the instructional card outside the live panel, below it, so
        // the user can try either edge without obscuring any metric row.
        let pagingGuideCardY = surfaceSize.height + 8.scaled(by: scale) + 37.scaled(by: scale)
        let runningModelsTargetX = visibility.embedsRunningThreadsInMetricsRow
            ? surfaceSize.width - 41.scaled(by: scale)
            : surfaceSize.width / 2
        let runningModelsTargetWidth = visibility.embedsRunningThreadsInMetricsRow
            ? 66.scaled(by: scale)
            : max(44.scaled(by: scale), surfaceSize.width - 20.scaled(by: scale))
        let runningModelsTargetY = FloatingTokenPanelMetrics.runningThreadsRowCenterY(
            visibility: visibility,
            panelHeight: surfaceSize.height,
            scale: scale
        ) ?? surfaceSize.height / 2
        // Trying either paging edge must not dismiss the guide. Completion is
        // reserved for the explicit guide button.
        let pageNavigationAction: (() -> Void)? = nil

        let runningModelDetailsSurfaceOffsetY = effectiveRunningModelDetailsPresented && detailsPlacement == .above
            ? size.height - surfaceSize.height : 0
        let detailsInset = FloatingTokenPanelMetrics.runningModelDetailsTrailingInset.scaled(by: scale)
        let detailsHeight = max(0, size.height - surfaceSize.height
            - FloatingTokenPanelMetrics.runningModelDetailsGap.scaled(by: scale) - detailsInset)

        return ZStack(alignment: .topLeading) {
            ZStack {
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
                    onPageNavigation: pageNavigationAction,
                    runningModelDetailsExpanded: effectiveRunningModelDetailsPresented,
                    onRunningThreadsActivate: pagingGuidePresented ? nil : {
                        runningModelDetailsSessionState.toggle()
                    },
                    guideMode: pagingGuidePresented && activePagingGuidePage == .paging
                )
                    .environment(\.tokenDisplayScale, scale)
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
                .zIndex(8)

                FloatingPanelCloseButton(
                    scale: scale,
                    action: onClose
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(8)
            }
            .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .offset(y: runningModelDetailsSurfaceOffsetY)

            if effectiveRunningModelDetailsPresented {
                FloatingRunningThreadModelDetailsCard(
                    summary: displaySnapshot.runningThreads,
                    scale: scale,
                    width: max(0, surfaceSize.width - 2 * detailsInset),
                    height: detailsHeight,
                    appearance: appearance,
                    isDemo: false,
                    onClose: {
                        runningModelDetailsSessionState.dismiss()
                    }
                )
                .offset(
                    x: detailsInset,
                    y: detailsPlacement == .above ? detailsInset
                        : surfaceSize.height + FloatingTokenPanelMetrics.runningModelDetailsGap.scaled(by: scale)
                )
                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.12).delay(0.1)))
                .zIndex(5)
            }

            if pagingGuidePresented {
                FloatingPanelPagingGuide(
                    page: activePagingGuidePage,
                    isLastPage: safePagingGuidePageIndex == pagingGuidePages.count - 1,
                    showsArrowGlyphs: Binding(
                        get: { pagingGuideShowsArrowGlyphs },
                        set: { value in
                            pagingGuideShowsArrowGlyphs = value
                            persistedPageNavigationArrows = value
                        }
                    ),
                    scale: scale,
                    appearance: appearance,
                    surfaceWidth: surfaceSize.width,
                    surfaceHeight: surfaceSize.height,
                    targetY: pagingGuideTargetY,
                    targetYs: safePagingGuideTargetYs,
                    calloutTargetY: pagingGuideCalloutY,
                    cardY: pagingGuideCardY,
                    showsDemoModelUsage: displaySnapshot.todayModelBreakdowns.isEmpty,
                    modelTargetX: runningModelsTargetX,
                    modelTargetY: runningModelsTargetY,
                    modelTargetWidth: runningModelsTargetWidth,
                    onAdvance: {
                        advancePagingGuide(pages: pagingGuidePages)
                    }
                )
                .zIndex(6)
            }
        }
        .onAppear {
            onPagingGuidePresentationChanged(pagingGuidePresented)
            onRunningModelDetailsPresentationChanged(effectiveRunningModelDetailsPresented)
            onRunningModelDetailsRowUnitsChanged(
                displaySnapshot.runningThreads.runningModelDetailsRowUnits
            )
        }
        .onChange(of: pagingGuidePresented) { _, presented in
            if presented {
                runningModelDetailsSessionState.dismiss()
                pagingGuidePageIndex = 0
            }
            onPagingGuidePresentationChanged(presented)
        }
        .onChange(of: effectiveRunningModelDetailsPresented) { _, presented in
            onRunningModelDetailsPresentationChanged(presented)
        }
        .onChange(of: displaySnapshot.runningThreads.runningModelDetailsRowUnits) { _, rowUnits in
            onRunningModelDetailsRowUnitsChanged(rowUnits)
        }
        .onChange(of: visibility.hasRunningThreadDetailsTarget) { _, hasTarget in
            if !hasTarget {
                runningModelDetailsSessionState.dismiss()
            }
        }
        .environment(\.tokenDisplayTextPalette, baseTextPalette)
        .environment(\.tokenDisplayRowTextPalettes, rowTextPalettes)
        .environment(\.tokenDisplayMetricTextPalettes, metricTextPalettes)
        .environment(\.tokenDisplayQuotaColorStyle, quotaColorStyle)
        .environment(\.tokenDisplayEmbeddedUsageStatusTextPalette, embeddedUsageStatusTextPalette)
        .environment(\.tokenDisplayStandaloneUsageStatusTextPalette, standaloneUsageStatusTextPalette)
        .environment(\.tokenDisplayRadarActionTextPalette, radarActionTextPalette)
        .environment(\.tokenDisplayRadarModelTextPalette, radarModelTextPalette)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            if effectiveRunningModelDetailsPresented {
                RoundedRectangle(cornerRadius: 18.scaled(by: scale), style: .continuous).fill(.black)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: unreadCount > 0)
        .modifier(FloatingEdgeDockModifier(presentation: edgeDockPresentation, size: size, quota: liveDisplaySnapshot.quota, quotaColorStyle: quotaColorStyle))
    }

    private func advancePagingGuide(pages: [FloatingPanelGuidePage]) {
        guard pagingGuidePageIndex + 1 >= pages.count else {
            pagingGuidePageIndex += 1
            return
        }
        completePagingGuide(pages: pages)
    }

    private func completePagingGuide(pages: [FloatingPanelGuidePage]) {
        let revision = pages.contains(.runningModels)
            ? FloatingPanelContentVisibility.currentPagingGuideRevision
            : FloatingPanelPagingGuideState.pagingLearnedRevision
        onPagingGuidePresentationChanged(false)
        pagingGuideSessionState.complete(
            revision: revision,
            showsArrowGlyphs: pagingGuideShowsArrowGlyphs
        )
        persistedPageNavigationArrows = pagingGuideShowsArrowGlyphs
        pagingGuideRevision = revision
        pagingGuidePageIndex = 0
    }

    func withLockTarget(_ description: String?) -> FloatingTokenPanelView {
        var copy = self
        copy.lockTargetDescription = description
        return copy
    }
}

func runningThreadControlFrames(
    layout: FloatingTokenPanelLayout,
    visibility: FloatingPanelContentVisibility
) -> [NSRect] {
    guard visibility.hasRunningThreadDetailsTarget else { return [] }
    let scale = layout.effectiveScale
    let surfaceSize = FloatingTokenPanelMetrics.size(
        effectiveScale: scale,
        visibility: visibility
    )
    guard let centerFromTop = FloatingTokenPanelMetrics.runningThreadsRowCenterY(
        visibility: visibility,
        panelHeight: surfaceSize.height,
        scale: scale
    ) else { return [] }
    let width = visibility.embedsRunningThreadsInMetricsRow
        ? 66.scaled(by: scale)
        : max(44.scaled(by: scale), surfaceSize.width - 20.scaled(by: scale))
    let height = 24.scaled(by: scale)
    let centerX = visibility.embedsRunningThreadsInMetricsRow
        ? surfaceSize.width - 41.scaled(by: scale)
        : surfaceSize.width / 2
    let surfaceOffsetY = layout.runningModelDetailsPresented && layout.runningModelDetailsPlacement == .above
        ? layout.size.height - surfaceSize.height : 0
    return [
        NSRect(
            x: centerX - width / 2,
            y: layout.size.height - surfaceOffsetY - centerFromTop - height / 2,
            width: width,
            height: height
        )
    ]
}

func runningModelDetailsCardFrame(layout: FloatingTokenPanelLayout, surfaceSize: NSSize) -> NSRect {
    let inset = FloatingTokenPanelMetrics.runningModelDetailsTrailingInset.scaled(by: layout.effectiveScale)
    let gap = FloatingTokenPanelMetrics.runningModelDetailsGap.scaled(by: layout.effectiveScale)
    let height = max(0, layout.size.height - surfaceSize.height - gap - inset)
    return NSRect(x: inset,
                  y: layout.runningModelDetailsPlacement == .above ? surfaceSize.height + gap : inset,
                  width: max(0, surfaceSize.width - 2 * inset), height: height)
}

@MainActor
func resizePanel(
    _ panel: NSPanel,
    layout: FloatingTokenPanelLayout,
    surfaceSize: NSSize? = nil,
    baseFrame: NSRect? = nil
) {
    let previousFrame = panel.frame
    let targetSize = layout.size
    let targetFrame: NSRect
    if layout.runningModelDetailsPresented,
       let surfaceSize,
       let baseFrame {
        targetFrame = FloatingTokenPanelResizePolicy.expandedFrame(
            baseFrame: baseFrame,
            expandedSize: targetSize,
            surfaceSize: surfaceSize,
            placement: layout.runningModelDetailsPlacement,
            screenFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
    } else if let baseFrame {
        targetFrame = anchoredPanelFrame(
            for: panel,
            size: targetSize,
            topLeft: NSPoint(x: baseFrame.minX, y: baseFrame.maxY),
            margin: 0
        )
    } else {
        targetFrame = anchoredPanelFrame(
            for: panel,
            size: targetSize,
            topLeft: NSPoint(x: previousFrame.minX, y: previousFrame.maxY)
        )
    }
    // Updating constraints and hosting bounds can cause intermediate AppKit
    // frames; present only the final native frame and matching content layout.
    panel.disableScreenUpdatesUntilFlush()
    panel.contentViewController?.view.frame = NSRect(origin: .zero, size: targetSize)
    panel.contentMinSize = targetSize
    panel.contentMaxSize = targetSize
    panel.setFrame(targetFrame, display: false, animate: false)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
}

@MainActor
func anchoredPanelFrame(for panel: NSPanel, size: NSSize, topLeft: NSPoint, margin: CGFloat = 8) -> NSRect {
    let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)

    if let screenFrame {
        origin.x = min(max(origin.x, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        origin.y = min(max(origin.y, screenFrame.minY + margin), screenFrame.maxY - size.height - margin)
    }

    return NSRect(origin: origin, size: size)
}
