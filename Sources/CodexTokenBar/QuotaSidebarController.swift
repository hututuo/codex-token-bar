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
    @Published private(set) var expandedContentHeight: CGFloat = QuotaSidebarLayout.weeklyExpandedHeight
    private(set) var hasFiveHour = false
    private var quotaObservation: AnyCancellable?
    private var heightBudget = QuotaSidebarHeightBudget()
    @Published private(set) var availableRailHeight: CGFloat = 900
    private var compactContentHeight: CGFloat?
    func updateCompactHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, compactContentHeight != height else { return }
        compactContentHeight = height
        if !interaction.expanded && !isCollapsing { updateFrames() }
    }

    // Keep the expanded layout fixed until the native collapse has settled.
    private var isCollapsing = false
    @Published private(set) var hiddenModules: Set<QuotaSidebarDetail> = []
    @Published private(set) var moduleOrder = QuotaSidebarDetail.defaultModuleOrder
    private var rebaseOnMeasurement = false
    private static let hiddenModulesKey = "quotaSidebarHiddenModules"
    private static let moduleOrderKey = "quotaSidebarModuleOrder"

    func isModuleVisible(_ module: QuotaSidebarDetail) -> Bool { !hiddenModules.contains(module) }
    func setModuleVisible(_ module: QuotaSidebarDetail, visible: Bool) {
        guard module != .settings else { return }
        guard visible != isModuleVisible(module) else { return }
        rebaseOnMeasurement = true
        if visible { hiddenModules.remove(module) } else { hiddenModules.insert(module) }
        settings.set(hiddenModules.map(\.rawValue).sorted(), forKey: Self.hiddenModulesKey)
    }

    func moveModule(_ module: QuotaSidebarDetail, by offset: Int) {
        guard let index = moduleOrder.firstIndex(of: module), moduleOrder.indices.contains(index + offset) else { return }
        var next = moduleOrder
        next.swapAt(index, index + offset)
        setModuleOrder(next)
    }

    func resetModuleOrder() { setModuleOrder(QuotaSidebarDetail.defaultModuleOrder) }

    private func setModuleOrder(_ order: [QuotaSidebarDetail]) {
        guard order != moduleOrder else { return }
        moduleOrder = order
        rebaseOnMeasurement = true
        settings.set(order.map(\.rawValue), forKey: Self.moduleOrderKey)
    }
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
    private var activationObserver: NSObjectProtocol?
    private var collapseTask: Task<Void, Never>?
    private var frameAnimationTask: QuotaSidebarFrameClock?
    private var frameAnimationGeneration = 0
    // Screen-space visual bounds while a fixed native window contains the reveal.
    private(set) var presentedRailFrame: CGRect?
    private var dashboardOpenAction: (() -> Void)?
    private var makeRail: (() -> AnyView)?
    private var makeDetail: (() -> AnyView)?
    private var detailContentMounted = false
    private var cacheAdviceID: String?
    private var lastPresentedCacheAdviceID: String?

    init(settings: UserDefaults = .standard) {
        self.settings = settings
        self.hiddenModules = Set((settings.stringArray(forKey: Self.hiddenModulesKey) ?? []).compactMap(QuotaSidebarDetail.init(rawValue:)).filter { $0 != .settings })
        self.moduleOrder = QuotaSidebarDetail.normalizedModuleOrder(settings.stringArray(forKey: Self.moduleOrderKey) ?? [])
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
            railPanel?.contentView = QuotaSidebarRevealView(canvas: QuotaSidebarCanvasView(host: railHost, edge: edge, signal: signal))
            quotaObservation = quota.$snapshot.sink { [weak self] snapshot in
                self?.updateQuotaSnapshot(snapshot)
            }
            installObservers()
        }
        if changedEdge { isCollapsing = false; interaction.dismiss() }
        updateFrames()
    }

    func close() {
        isCollapsing = false
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
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        localMonitor = nil; globalMonitor = nil; screenObserver = nil; activationObserver = nil
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

    func updateContentMeasurement(_ measurement: QuotaSidebarContentMeasurement) {
        let previous = heightBudget.targetHeight
        heightBudget.update(contentHeight: measurement.contentHeight,
                            rowHeight: isModuleVisible(.speeds) ? measurement.speedRowHeight : 0,
                            expanded: interaction.expanded || isCollapsing, rebase: rebaseOnMeasurement)
        rebaseOnMeasurement = false
        if previous != heightBudget.targetHeight { updateFrames() }
    }

    // Quota presence changes layout only, preserving the selected detail tab and pin.
    func updateQuotaSnapshot(_ snapshot: AccountQuotaSnapshot) {
        let present = snapshot.fiveHour != nil
        guard hasFiveHour != present else { return }
        hasFiveHour = present
        updateFrames()
    }

    func enter() {
        guard !isTrackingPress, !isDragging else { return }
        collapseTask?.cancel(); collapseTask = nil
        if interaction.expanded {
            if interaction.cacheNoticeID != nil && !interaction.cacheNoticePointerEntered { interaction.enter() }
            return
        }
        isCollapsing = false
        interaction.enter()
        updateFrames()
    }

    func select(_ detail: QuotaSidebarDetail, section: String = "top") {
        guard !isTrackingPress, !isDragging else { return }
        collapseTask?.cancel(); collapseTask = nil
        detailScrollTarget = section
        isCollapsing = false
        interaction.select(detail)
        detailScrollRevision += 1
        updateFrames()
    }

    func openDashboard() { dashboardOpenAction?() }

    func togglePin() { interaction.togglePin(); pointerMoved() }

    func dismiss() {
        collapseTask?.cancel(); collapseTask = nil
        if let id = interaction.cacheNoticeID {
            settings.set(id, forKey: "cacheHitAdviceDismissed")
            cacheAdviceID = nil
        }
        isCollapsing = interaction.expanded && railPanel?.isVisible == true
        interaction.dismiss()
        updateFrames()
    }

    private func finishCollapse() {
        guard isCollapsing, !interaction.expanded else { return }
        isCollapsing = false
        // Rearm the next opening only after reaching the compact frame. This
        // avoids resizing the hidden SwiftUI tree in the shrinking frame loop.
        heightBudget.update(expanded: false)
        updateFrames()
    }

    private static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func trackPress(_ down: NSEvent) -> Bool {
        guard let panel = railPanel, !isTrackingPress else { return false }
        // Expanded controls must receive AppKit's original down/up sequence.
        // Replaying it after a nested drag loop can lose SwiftUI button tracking.
        let visualFrame = presentedRailFrame ?? panel.frame
        let visualPoint = CGPoint(x: down.locationInWindow.x + panel.frame.minX - visualFrame.minX,
                                  y: down.locationInWindow.y + panel.frame.minY - visualFrame.minY)
        guard QuotaSidebarPressRouting.shouldTrackDrag(expanded: interaction.expanded,
            point: visualPoint, size: visualFrame.size) else { return false }
        // Freeze in place until this press becomes a drag. A short click must keep
        // the original window coordinates for AppKit's down/up tracking sequence.
        cancelFrameAnimation(settle: false)
        let generation = trackingGeneration
        isTrackingPress = true
        collapseTask?.cancel(); collapseTask = nil
        var session = QuotaSidebarDragSession(startPoint: NSEvent.mouseLocation, startFrame: visualFrame)
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
                    settleRailPresentation()
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
                } else {
                    if let event { panel.replayClick(down: down, up: event) }
                    // A lost mouse-up also releases the frozen reveal, even
                    // though there is no event pair safe to replay as a click.
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
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.keyCode == 53, self?.interaction.expanded == true { self?.dismiss() }
                } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                    self?.outsideClick()
                } else { self?.pointerMoved() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { self?.outsideClick() }
                else { self?.pointerMoved() }
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.interaction.cacheNoticeID != nil, !self.interaction.pinned,
                      !self.isDragging, !self.isTrackingPress else { return }
                self.dismiss()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrames() }
        }
    }

    private func outsideClick() {
        guard interaction.expanded, !interaction.pinned, !isDragging, !isTrackingPress,
              let frames, !frames.contains(NSEvent.mouseLocation, detailVisible: interaction.detail != nil) else { return }
        dismiss()
    }

    private func pointerMoved() {
        updateRevealInputRegion()
        guard !isTrackingPress, !isDragging else { return }
        guard let frames else { return }
        if frames.contains(NSEvent.mouseLocation, detailVisible: interaction.detail != nil) {
            enter()
        } else if interaction.expanded && interaction.allowsAutomaticCollapse && collapseTask == nil {
            collapseTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
                guard let self else { return }
                self.collapseTask = nil
                guard let frames = self.frames,
                      !frames.contains(NSEvent.mouseLocation, detailVisible: self.interaction.detail != nil) else { return }
                guard self.interaction.allowsAutomaticCollapse else { return }
                self.dismiss()
            }
        }
    }

    private func cancelFrameAnimation(settle: Bool = true) {
        frameAnimationGeneration &+= 1
        frameAnimationTask?.cancel()
        frameAnimationTask = nil
        if settle { settleRailPresentation() }
    }

    private func settleRailPresentation() {
        guard let panel = railPanel, let visual = presentedRailFrame else { return }
        presentedRailFrame = nil
        if panel.frame != visual { panel.setFrame(visual, display: false, animate: false) }
        (panel.contentView as? QuotaSidebarRevealView)?.present(nil)
        panel.ignoresMouseEvents = false
    }

    private func updateRevealInputRegion() {
        guard let panel = railPanel else { return }
        // Transparent envelope pixels must not intercept another application's
        // click. The compact endpoint returns to an actual 16pt native window.
        let ignore = presentedRailFrame.map { !$0.contains(NSEvent.mouseLocation) } ?? false
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
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
        (railPanel.contentView as? QuotaSidebarRevealView)?.canvas.edge = edge
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
        if availableRailHeight != screen.visibleFrame.height { availableRailHeight = screen.visibleFrame.height }
        heightBudget.update(expanded: interaction.expanded || isCollapsing)
        let expandedTarget = QuotaSidebarFrames.make(usableFrame: screen.visibleFrame, edge: edge,
            expanded: true, scale: screen.backingScaleFactor, hasFiveHour: hasFiveHour,
            normalizedY: placement?.normalizedY ?? 0.5, expandedHeight: heightBudget.targetHeight, compactHeight: compactContentHeight)
        let next = QuotaSidebarFrames.make(usableFrame: screen.visibleFrame, edge: edge,
                                          expanded: interaction.expanded, scale: screen.backingScaleFactor,
                                          hasFiveHour: hasFiveHour, normalizedY: placement?.normalizedY ?? 0.5, expandedHeight: heightBudget.targetHeight, compactHeight: compactContentHeight)
        let previous = frames
        // The host keeps a stable canvas for reveal animation, but a weekly-only
        // or short-screen rail clips that canvas. Fit full-panel notices to
        // the settled visible height, not the stable animation canvas.
        if !isCollapsing {
            if expandedContentHeight != expandedTarget.rail.height {
                expandedContentHeight = expandedTarget.rail.height
            }
            if let canvas = (railPanel.contentView as? QuotaSidebarRevealView)?.canvas {
                canvas.canvasHeight = max(QuotaSidebarLayout.expandedCanvasHeight, expandedTarget.rail.height)
            }
        }
        frames = next
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reducedMotion { cancelFrameAnimation() }
        if previous?.rail != next.rail || (frameAnimationTask == nil && (railPanel.frame != next.rail || presentedRailFrame != nil)) {
            let current = presentedRailFrame ?? railPanel.frame
            // Reversals keep the exact subpixel visual position. Shrinking the
            // native envelope first would round it and cause a visible jump.
            cancelFrameAnimation(settle: false)
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
                var compactFramePresented = false
                // Allocate the union once. Only an NSView clip moves on display ticks;
                // resizing NSWindow every frame synchronously queries WindowServer.
                let requestedEnvelope = current.union(next.rail)
                presentedRailFrame = current
                if railPanel.frame != requestedEnvelope { railPanel.setFrame(requestedEnvelope, display: false, animate: false) }
                // AppKit may align the requested origin to its backing coordinates.
                let envelope = railPanel.frame
                (railPanel.contentView as? QuotaSidebarRevealView)?.present(current.offsetBy(dx: -envelope.minX, dy: -envelope.minY))
                updateRevealInputRegion()
                frameAnimationTask = clock
                clock.start(screen: screen) { [weak self, weak railPanel] in
                    guard let self, let railPanel, self.frameAnimationGeneration == generation,
                          self.railPanel === railPanel, railPanel.isVisible,
                          !self.isTrackingPress, !self.isDragging else { return false }
                    if compactFramePresented {
                        self.frameAnimationTask = nil
                        self.finishCollapse()
                        return false
                    }
                    let time = min(1, (CACurrentMediaTime() - started) / duration)
                    let reduceNow = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    let frame = reduceNow ? next.rail
                        : snap ? QuotaSidebarMotion.snapFrame(from: current, to: next.rail, time: time, area: area, scale: scale)
                        : QuotaSidebarMotion.frame(from: current, to: next.rail, time: time,
                            expanding: expanding, edge: animationEdge, area: area, scale: scale)
                    self.presentedRailFrame = frame
                    (railPanel.contentView as? QuotaSidebarRevealView)?.present(frame.offsetBy(dx: -envelope.minX, dy: -envelope.minY))
                    self.updateRevealInputRegion()
                    if time >= 1 || reduceNow {
                        self.settleRailPresentation()
                        // Allow the final compact frame to be presented before
                        // the next display tick applies the hidden content size.
                        if self.isCollapsing && !reduceNow {
                            compactFramePresented = true
                            return true
                        }
                        self.frameAnimationTask = nil
                        self.finishCollapse()
                        return false
                    }
                    return true
                }

            } else {
                presentedRailFrame = nil
                if railPanel.frame != next.rail { railPanel.setFrame(next.rail, display: true, animate: false) }
                (railPanel.contentView as? QuotaSidebarRevealView)?.present(nil)
                railPanel.ignoresMouseEvents = false
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
        if frameAnimationTask == nil, railPanel.frame == next.rail { finishCollapse() }
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


/// Transparent, fixed-size native envelope used only while the canvas reveals.
/// The canvas owns rounded clipping, background, signal and grip as one subtree.
@MainActor
final class QuotaSidebarRevealView: NSView {
    let canvas: QuotaSidebarCanvasView
    private var visualBounds: CGRect?
    init(canvas: QuotaSidebarCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { nil }
    func present(_ rect: CGRect?) {
        visualBounds = rect
        layoutCanvas()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutCanvas() }
    override func layout() { super.layout(); layoutCanvas() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard (visualBounds ?? bounds).contains(local) else { return nil }
        return super.hitTest(point)
    }
    private func layoutCanvas() {
        let rect = visualBounds ?? bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if canvas.frame.size != rect.size { canvas.setFrameSize(rect.size) }
        if canvas.frame.origin != rect.origin { canvas.setFrameOrigin(rect.origin) }
        CATransaction.commit()
    }
}

/// A stable drawing canvas inside the reveal envelope (tight at rest).
/// Only its clip changes during reveal; SwiftUI never lays out in a 16pt proposal.
@MainActor
final class QuotaSidebarCanvasView: NSView {
    let host: NSView
    let signal: NSView?
    let dragHandle = QuotaSidebarDragHandleView()
    var canvasHeight: CGFloat = QuotaSidebarLayout.expandedCanvasHeight { didSet { if oldValue != canvasHeight { layoutCanvas() } } }
    var edge: QuotaSidebarEdge { didSet { if oldValue != edge { layoutCanvas() } } }
    init(host: NSView, edge: QuotaSidebarEdge, signal: NSView? = nil) {
        self.host = host; self.edge = edge; self.signal = signal
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 1).cgColor
        addSubview(host); if let signal { addSubview(signal) }
        addSubview(dragHandle)
        layoutCanvas()
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutCanvas() }
    override func layout() { super.layout(); layoutCanvas() }
    private func layoutCanvas() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hostFrame = CGRect(x: edge == .right ? bounds.width - 88 : 0,
                               y: (bounds.height - canvasHeight) / 2, width: 88, height: canvasHeight)
        // Moving the reveal canvas must not call NSHostingView.setFrameSize:
        // assigning a complete frame also invalidates its SwiftUI layout when
        // only the origin changed. The content size stays fixed while clipping.
        if host.frame.size != hostFrame.size { host.setFrameSize(hostFrame.size) }
        if host.frame.origin != hostFrame.origin { host.setFrameOrigin(hostFrame.origin) }
        if let signal, signal.frame != bounds { signal.frame = bounds }
        let gripFrame = QuotaSidebarPressRouting.dragHandleFrame(in: bounds)
        if dragHandle.frame != gripFrame { dragHandle.frame = gripFrame }
        dragHandle.isHidden = bounds.width <= 16
        layer?.cornerRadius = min(22, max(8, 8 + (bounds.width - 16) * 14 / 72))
        layer?.maskedCorners = edge == .right ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        CATransaction.commit()
    }
}

/// Lives in the real native clip, so it stays at the visible top on short
/// displays and while the stable SwiftUI canvas is being revealed or collapsed.
@MainActor
final class QuotaSidebarDragHandleView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 0.65).cgColor
        layer?.cornerRadius = 1.5
        identifier = NSUserInterfaceItemIdentifier("quota-sidebar-drag-handle")
        toolTip = "按住拖动侧栏，可移到其他屏幕"
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("拖动侧栏，可移到其他屏幕")
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
