import AppKit
import Combine
import SwiftUI
import QuartzCore

@MainActor
final class QuotaSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var trackPrimaryPress: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, trackPrimaryPress?(event) == true { return }
        super.sendEvent(event)
    }

    // A short press is replayed only after drag tracking decides it was a
    // click. Buttons never receive a half-finished mouse sequence on drag.
    func replayClick(down: NSEvent, up: NSEvent) {
        // Queue mouse-up before dispatching down: AppKit-backed controls may
        // run their own tracking loop inside mouseDown and must find the up.
        NSApplication.shared.postEvent(up, atStart: true)
        super.sendEvent(down)
    }
}

@MainActor
final class QuotaSidebarHostingView<Content: View>: NSHostingView<Content> {
    // A nonactivating sidebar must respond to the first click while another
    // app is frontmost, without trying to become key or activating Token Bar.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class QuotaSidebarController: NSObject, ObservableObject {
    @Published private(set) var interaction = QuotaSidebarInteraction()
    @Published private(set) var detailScrollRevision = 0
    private(set) var detailScrollTarget = "top"
    private(set) var railPanel: QuotaSidebarPanel?
    private(set) var detailPanel: QuotaSidebarPanel?
    @Published private(set) var edge = QuotaSidebarEdge.right
    private(set) var hasFiveHour = false
    private var quotaObservation: AnyCancellable?
    private let settings: UserDefaults
    private(set) var placement: QuotaSidebarPlacement?
    private(set) var isDragging = false
    private var isTrackingPress = false
    private var trackingGeneration = 0
    private var screen: NSScreen?
    private var frames: QuotaSidebarFrames?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var collapseTask: Task<Void, Never>?
    private var frameAnimationTask: QuotaSidebarFrameClock?
    private var frameAnimationGeneration = 0
    private var dashboardOpenAction: (() -> Void)?
    private var makeRail: (() -> AnyView)?
    private var makeDetail: (() -> AnyView)?
    private var detailContentMounted = false
    private var cacheAdviceID: String?
    private var lastPresentedCacheAdviceID: String?

    init(settings: UserDefaults = .standard) {
        self.settings = settings
        self.placement = QuotaSidebarPlacement.load(defaults: settings)
        super.init()
    }

    func show(store: CodexUsageStore, monitor: LiveRateMonitor, quota: AccountQuotaStore,
              tasks: TaskCompletionMonitor, radar: CodexRadarStore, history: QuotaHistoryStore, edge: QuotaSidebarEdge, onOpenDashboard: @escaping () -> Void = {}) {
        guard !isTrackingPress, !isDragging else { return }
        dashboardOpenAction = onOpenDashboard
        let resolvedEdge = QuotaSidebarPlacement.resolvedEdge(requested: edge, defaults: settings)
        let changedEdge = self.edge != resolvedEdge
        if changedEdge { self.edge = resolvedEdge }
        if railPanel == nil {
            screen = NSScreen.screens.first { Self.displayID($0) == placement?.displayID }
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main ?? NSScreen.screens.first
            makeRail = { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(QuotaSidebarRail(controller: self, store: store, quota: quota, tasks: tasks, radar: radar, monitor: monitor))
            }
            makeDetail = { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(QuotaSidebarDetailView(controller: self, store: store, monitor: monitor, quota: quota, tasks: tasks, radar: radar, history: history))
            }
            railPanel = makePanel(identifier: "CodexTokenBarQuotaSidebar")
            railPanel?.trackPrimaryPress = { [weak self] event in self?.trackPress(event) ?? false }
            detailPanel = makePanel(identifier: "CodexTokenBarQuotaSidebarDetail")
            detailPanel?.contentView = nil
            detailContentMounted = false
            let railHost = QuotaSidebarHostingView(rootView: makeRail?())
            // Explicit native geometry owns these windows, including 16 pt
            // collapse; SwiftUI's intrinsic minimum must not resize them.
            railHost.sizingOptions = []
            let signal = QuotaSidebarSignalHost(rootView: QuotaSidebarNativeSignal(controller: self, radar: radar))
            signal.sizingOptions = []
            railPanel?.contentView = QuotaSidebarCanvasView(host: railHost, edge: edge, signal: signal)
            quotaObservation = quota.$snapshot.sink { [weak self] snapshot in
                self?.updateQuotaSnapshot(snapshot)
            }
            installObservers()
        }
        if changedEdge { interaction.dismiss() }
        updateFrames()
    }

    func close() {
        cancelFrameAnimation()
        trackingGeneration &+= 1
        isTrackingPress = false
        isDragging = false
        railPanel?.trackPrimaryPress = nil
        quotaObservation?.cancel()
        quotaObservation = nil
        collapseTask?.cancel()
        collapseTask = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        localMonitor = nil; globalMonitor = nil; screenObserver = nil
        railPanel?.orderOut(nil); detailPanel?.orderOut(nil)
        railPanel = nil; detailPanel = nil
        detailContentMounted = false
        makeRail = nil; makeDetail = nil; frames = nil; screen = nil
        cacheAdviceID = nil; lastPresentedCacheAdviceID = nil
        interaction.dismiss()
    }

    func updateCacheAdvice(_ id: String?) {
        cacheAdviceID = id
        if id == nil { interaction.presentCacheAdvice(nil) }
        updateFrames()
        if id == nil { pointerMoved() }
    }

    // Quota presence changes layout only. A refreshed account snapshot must
    // not reset a selected detail tab or the user's pinned state.
    func updateQuotaSnapshot(_ snapshot: AccountQuotaSnapshot) {
        let present = snapshot.fiveHour != nil
        guard hasFiveHour != present else { return }
        hasFiveHour = present
        updateFrames()
    }

    func enter() {
        guard !isTrackingPress, !isDragging else { return }
        collapseTask?.cancel(); collapseTask = nil
        guard !interaction.expanded else { return }
        interaction.enter()
        updateFrames()
    }

    func select(_ detail: QuotaSidebarDetail, section: String = "top") {
        guard !isTrackingPress, !isDragging else { return }
        collapseTask?.cancel(); collapseTask = nil
        detailScrollTarget = section
        interaction.select(detail)
        detailScrollRevision += 1
        updateFrames()
    }

    func openDashboard() { dashboardOpenAction?() }

    func togglePin() { interaction.togglePin(); pointerMoved() }

    func dismiss() {
        collapseTask?.cancel(); collapseTask = nil
        interaction.dismiss()
        updateFrames()
    }

    private static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func trackPress(_ down: NSEvent) -> Bool {
        guard let panel = railPanel, !isTrackingPress else { return false }
        // Expanded controls must receive AppKit's original down/up sequence.
        // Replaying it after a nested drag loop can lose SwiftUI button tracking.
        guard QuotaSidebarPressRouting.shouldTrackDrag(expanded: interaction.expanded,
            point: down.locationInWindow, size: panel.frame.size) else { return false }
        cancelFrameAnimation()
        let generation = trackingGeneration
        isTrackingPress = true
        collapseTask?.cancel(); collapseTask = nil
        var session = QuotaSidebarDragSession(startPoint: NSEvent.mouseLocation, startFrame: panel.frame)
        var cursorPushed = false
        defer {
            if cursorPushed { NSCursor.pop() }
            if generation == trackingGeneration { isTrackingPress = false; isDragging = false }
        }
        while generation == trackingGeneration {
            let event = NSApplication.shared.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking, dequeue: true
            )
            guard generation == trackingGeneration, railPanel === panel else { return true }
            let released = event?.type == .leftMouseUp
                || (event == nil && NSEvent.pressedMouseButtons & 1 == 0)
            // A bounded poll lets close/disable cancel ownership and recovers
            // if AppKit loses the final mouse-up during a display transition.
            if event == nil && !released { continue }
            let pointer = NSEvent.mouseLocation
            if let draggedFrame = session.update(to: pointer) {
                if !isDragging {
                    isDragging = true
                    interaction.beginDrag()
                    hideDetail()
                    // Stop an in-flight hover resize, then anchor at the real
                    // frame and pointer at threshold crossing, not stale 16 pt
                    // geometry captured before hover expansion.
                    let actualFrame = panel.frame
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        panel.animator().setFrame(actualFrame, display: true)
                    }
                    if released {
                        // A coalesced or lost-up sequence may contain no drag
                        // samples. Still apply its real final pointer delta.
                        let finalFrame = actualFrame.offsetBy(dx: pointer.x - session.startPoint.x,
                                                              dy: pointer.y - session.startPoint.y)
                        panel.setFrame(finalFrame, display: true, animate: false)
                        session.reanchor(point: pointer, frame: finalFrame)
                    } else {
                        session.reanchor(point: pointer, frame: actualFrame)
                    }
                    NSCursor.closedHand.push(); cursorPushed = true
                } else {
                    panel.setFrame(draggedFrame, display: true, animate: false)
                }
            }
            if released {
                isTrackingPress = false
                isDragging = false
                if session.didDrag {
                    finishDrag(pointer: pointer, frame: panel.frame)
                } else if let event {
                    panel.replayClick(down: down, up: event)
                    updateFrames()
                }
                return true
            }
        }
        return true
    }

    private func finishDrag(pointer: CGPoint, frame: CGRect) {
        guard railPanel != nil else { return }
        let screens = NSScreen.screens
        guard let index = QuotaSidebarPlacement.nearestScreenIndex(to: pointer, frames: screens.map(\.frame)) else { return }
        let selected = screens[index]
        let newEdge = QuotaSidebarPlacement.edge(at: pointer, usableFrame: selected.visibleFrame)
        let saved = QuotaSidebarPlacement(displayID: Self.displayID(selected),
            normalizedY: QuotaSidebarPlacement.fraction(centerY: frame.midY, usableFrame: selected.visibleFrame))
        screen = selected
        placement = saved
        edge = newEdge
        // Persist once, on release. A defaults-driven surface report during
        // these writes sees the finished native placement and selected side.
        settings.set(newEdge.rawValue, forKey: QuotaSidebarSettings.edgeKey)
        saved.save(defaults: settings)
        frames = nil
        updateFrames(animateDocking: true)
        pointerMoved()
    }

    private func makePanel(identifier: String) -> QuotaSidebarPanel {
        let panel = QuotaSidebarPanel(contentRect: .zero,
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func installObservers() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.keyCode == 53, self?.interaction.expanded == true { self?.dismiss() }
                } else { self?.pointerMoved() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrames() }
        }
    }

    private func pointerMoved() {
        guard !isTrackingPress, !isDragging else { return }
        guard let frames else { return }
        if frames.contains(NSEvent.mouseLocation, detailVisible: interaction.detail != nil) {
            enter()
        } else if interaction.expanded && !interaction.pinned && interaction.cacheNoticeID == nil && collapseTask == nil {
            collapseTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
                guard let self else { return }
                self.collapseTask = nil
                guard let frames = self.frames,
                      !frames.contains(NSEvent.mouseLocation, detailVisible: self.interaction.detail != nil) else { return }
                self.interaction.leaveAfterGrace()
                self.updateFrames()
            }
        }
    }

    private func cancelFrameAnimation() {
        frameAnimationGeneration &+= 1
        frameAnimationTask?.cancel()
        frameAnimationTask = nil
    }

    private func hideDetail() {
        if detailPanel?.isVisible == true { detailPanel?.orderOut(nil) }
        // A hidden hosting tree still receives ObservableObject publications.
        // Drop it while closed; opening builds a fresh view from current stores.
        if detailContentMounted { detailPanel?.contentView = nil; detailContentMounted = false }
    }

    private func updateFrames(animateDocking: Bool = false) {
        guard !isTrackingPress, !isDragging else { return }
        guard let railPanel else { return }
        // Defer while dragging; a new request opens only level two and never
        // activates the app or changes a selected/pinned detail.
        if let id = cacheAdviceID, id != lastPresentedCacheAdviceID {
            lastPresentedCacheAdviceID = id
            collapseTask?.cancel(); collapseTask = nil
            interaction.presentCacheAdvice(id)
        }
        (railPanel.contentView as? QuotaSidebarCanvasView)?.edge = edge
        // Preserve the chosen physical display until it disappears. A change
        // of scale or usable bounds recomputes Cocoa point/pixel placement.
        screen = NSScreen.screens.first { Self.displayID($0) == placement?.displayID }
            ?? NSScreen.screens.first { Self.displayID($0) == screen.map(Self.displayID) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            cancelFrameAnimation()
            railPanel.orderOut(nil); hideDetail()
            return
        }
        let next = QuotaSidebarFrames.make(usableFrame: screen.visibleFrame, edge: edge,
                                          expanded: interaction.expanded, scale: screen.backingScaleFactor,
                                          hasFiveHour: hasFiveHour, normalizedY: placement?.normalizedY ?? 0.5)
        let previous = frames
        frames = next
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reducedMotion { cancelFrameAnimation() }
        if previous?.rail != next.rail || (frameAnimationTask == nil && railPanel.frame != next.rail) {
            cancelFrameAnimation()
            let current = railPanel.frame
            let sameEdge = abs((edge == .left ? current.minX : current.maxX)
                               - (edge == .left ? next.rail.minX : next.rail.maxX)) < 1
            let snap = animateDocking && abs(current.minX - next.rail.minX) <= 160
                && screen.visibleFrame.intersects(current) && current != next.rail
            let resize = previous != nil
                && sameEdge && screen.visibleFrame.contains(current)
                && current.size != next.rail.size
            let canAnimate = railPanel.isVisible && !reducedMotion && (snap || resize)
            if canAnimate {
                let expanding = next.rail.width > current.width || next.rail.height > current.height
                let duration = snap ? 0.22 : (expanding ? 0.44 : 0.24)
                let started = CACurrentMediaTime()
                let animationEdge = edge
                let area = screen.visibleFrame
                let scale = screen.backingScaleFactor
                let generation = frameAnimationGeneration
                let clock = QuotaSidebarFrameClock()
                frameAnimationTask = clock
                clock.start(screen: screen) { [weak self, weak railPanel] in
                    guard let self, let railPanel, self.frameAnimationGeneration == generation,
                          self.railPanel === railPanel, railPanel.isVisible,
                          !self.isTrackingPress, !self.isDragging else { return false }
                    let time = min(1, (CACurrentMediaTime() - started) / duration)
                    let reduceNow = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    let frame = reduceNow ? next.rail
                        : snap ? QuotaSidebarMotion.snapFrame(from: current, to: next.rail, time: time, area: area, scale: scale)
                        : QuotaSidebarMotion.frame(from: current, to: next.rail, time: time,
                            expanding: expanding, edge: animationEdge, area: area, scale: scale)
                    if railPanel.frame != frame { railPanel.setFrame(frame, display: true, animate: false) }
                    if time >= 1 || reduceNow { self.frameAnimationTask = nil; return false }
                    return true
                }

            } else {
                if railPanel.frame != next.rail { railPanel.setFrame(next.rail, display: true, animate: false) }
            }
        }
        if !railPanel.isVisible { railPanel.orderFrontRegardless() }
        if interaction.detail != nil && next.detail.width > 0 {
            if !detailContentMounted {
                let host = QuotaSidebarHostingView(rootView: makeDetail?())
                host.sizingOptions = []
                detailPanel?.contentView = host
                detailContentMounted = true
            }
            if detailPanel?.frame != next.detail { detailPanel?.setFrame(next.detail, display: true, animate: false) }
            if detailPanel?.isVisible != true { detailPanel?.orderFrontRegardless() }
        } else { hideDetail() }
    }
}


@MainActor
private final class QuotaSidebarFrameClock: NSObject {
    private var link: CADisplayLink?
    private var step: (() -> Bool)?
    func start(screen: NSScreen, step: @escaping () -> Bool) {
        self.step = step
        let hz = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : min(120, max(60, screen.maximumFramesPerSecond))
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(hz), preferred: Float(hz))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick() { if step?() != true { cancel() } }
    func cancel() { link?.invalidate(); link = nil; step = nil }
}


/// A stable drawing canvas inside the actual, tightly sized input window.
/// Only its clip changes during reveal; SwiftUI never lays out in a 16pt proposal.
@MainActor
final class QuotaSidebarCanvasView: NSView {
    let host: NSView
    let signal: NSView?
    var edge: QuotaSidebarEdge { didSet { if oldValue != edge { layoutCanvas() } } }
    init(host: NSView, edge: QuotaSidebarEdge, signal: NSView? = nil) {
        self.host = host; self.edge = edge; self.signal = signal
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 1).cgColor
        addSubview(host); if let signal { addSubview(signal) }; layoutCanvas()
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutCanvas() }
    override func layout() { super.layout(); layoutCanvas() }
    private func layoutCanvas() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hostFrame = CGRect(x: edge == .right ? bounds.width - 88 : 0,
                               y: (bounds.height - 560) / 2, width: 88, height: 560)
        if host.frame != hostFrame { host.frame = hostFrame }
        if let signal, signal.frame != bounds { signal.frame = bounds }
        layer?.cornerRadius = min(22, max(8, 8 + (bounds.width - 16) * 14 / 72))
        layer?.maskedCorners = edge == .right ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        CATransaction.commit()
    }
}


@MainActor
private final class QuotaSidebarSignalHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct QuotaSidebarNativeSignal: View {
    @ObservedObject var controller: QuotaSidebarController
    @ObservedObject var radar: CodexRadarStore
    var body: some View {
        QuotaSidebarRadarOutline(edge: controller.edge, expanded: controller.interaction.expanded,
            snapshot: radar.snapshot, stale: radar.staleDataDisplayed, updatedAt: radar.lastSuccessfulRefreshAt)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
