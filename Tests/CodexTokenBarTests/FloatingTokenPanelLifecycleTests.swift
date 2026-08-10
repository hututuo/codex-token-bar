import AppKit
import XCTest
@testable import CodexTokenBar

@MainActor
final class FloatingTokenPanelLifecycleTests: XCTestCase {
    func testQuartzConversionBaselineUsesPrimaryScreenNotTallestScreen() {
        let primary = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let secondaryAbove = NSRect(x: 0, y: 800, width: 1_000, height: 600)

        // 副屏在主屏上方：基准必须仍是主屏 maxY(800)，而不是全局最高 1400，
        // 否则窗口定位/AX 命中/跟随整体偏移一个副屏高度。
        XCTAssertEqual(
            FloatingPanelScreenGeometry.conversionBaseline(
                orderedScreenFrames: [primary, secondaryAbove],
                mainScreenFrame: secondaryAbove
            ),
            800
        )
        XCTAssertEqual(
            FloatingPanelScreenGeometry.conversionBaseline(
                orderedScreenFrames: [],
                mainScreenFrame: primary
            ),
            800,
            "无屏列表时回退 main 屏"
        )
    }

    func testFloatingPanelCannotBecomeKeyOrMain() {
        let panel = makePanel()
        defer { panel.close() }

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.isMovableByWindowBackground)
    }

    func testPanelMousePolicySeparatesDragDoubleClickAndControls() {
        let panel = makePanel()
        defer { panel.close() }
        panel.allowsBackgroundDrag = true
        panel.controlExclusionSize = 52

        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 120, y: 40)),
            .dragPanel
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 120, y: 40)),
            .openDashboard
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 8, y: 88)),
            .passThrough
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 250, y: 88)),
            .passThrough
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 8, y: 20)),
            .passThrough,
            "分页箭头使用整条左右交互带，不能被背景拖拽吞掉"
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 48, y: 20)),
            .passThrough,
            "透明命中区向内容侧扩展后仍必须交给分页按钮"
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 250, y: 20)),
            .passThrough,
            "分页箭头使用整条左右交互带，不能被背景拖拽吞掉"
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 210, y: 20)),
            .passThrough,
            "右侧透明命中区向内容侧扩展后仍必须交给分页按钮"
        )

        panel.suppressesBackgroundMouseActions = true
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 120, y: 40)),
            .passThrough,
            "翻页引导显示时，中央单击必须交给 SwiftUI 按钮"
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 120, y: 40)),
            .passThrough,
            "翻页引导显示时，中央双击也不能抢走 SwiftUI 按钮事件"
        )

        panel.suppressesBackgroundMouseActions = false
        panel.allowsBackgroundDrag = false
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 120, y: 40)),
            .passThrough
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 120, y: 40)),
            .openDashboard
        )
    }

    func testProductionPanelEventOnlyOpensDashboardOnDoubleClick() throws {
        let panel = makePanel()
        defer { panel.close() }
        var openCount = 0
        panel.onOpenDashboard = { openCount += 1 }
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 120, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))

        panel.sendEvent(doubleClick)

        XCTAssertEqual(openCount, 1)

        panel.suppressesBackgroundMouseActions = true
        panel.sendEvent(doubleClick)

        XCTAssertEqual(openCount, 1, "翻页引导显示时，窗口层不能再拦截双击打开主界面")
    }

    func testEventSourcesInstallOncePerPresentationAndAreRemovedOnClose() {
        var installs = 0
        var removals = 0
        let lifecycle = FloatingPanelEventSourceLifecycle(
            install: { installs += 1 },
            remove: { removals += 1 }
        )

        XCTAssertEqual(installs, 0)
        XCTAssertEqual(removals, 0)

        lifecycle.activate()
        lifecycle.activate()
        XCTAssertEqual(installs, 1)

        lifecycle.deactivate()
        lifecycle.deactivate()
        XCTAssertEqual(removals, 1)

        lifecycle.activate()
        XCTAssertEqual(installs, 2)
        XCTAssertEqual(removals, 1)
    }

    func testExternalMouseRelevanceSeparatesRecordingFromInspection() {
        XCTAssertFalse(
            FloatingPanelExternalEventRelevance.shouldRecordClick(
                isPresented: false
            )
        )
        XCTAssertTrue(
            FloatingPanelExternalEventRelevance.shouldRecordClick(
                isPresented: true
            )
        )
        XCTAssertFalse(
            FloatingPanelExternalEventRelevance.shouldInspectWindow(
                isPresented: true,
                isLocked: false,
                hasLockedAnchor: false,
                hasActiveDrag: false
            )
        )
    }

    func testClosedControllerClickDoesNotCallAccessibilityOrWindowProviders() {
        let controller = FloatingTokenPanelController()
        var accessibilityCalls = 0
        var windowCalls = 0
        controller.externalClickAccessibilityTargetProvider = { _ in
            accessibilityCalls += 1
            return nil
        }
        controller.externalClickVisibleWindowsProvider = {
            windowCalls += 1
            return []
        }

        controller.recordExternalMouseClick(at: .zero)

        XCTAssertEqual(accessibilityCalls, 0)
        XCTAssertEqual(windowCalls, 0)
    }

    func testUnlockedClickRecordsLocationAndDefersWindowResolutionUntilLock() {
        let controller = FloatingTokenPanelController()
        var isLocked = false
        controller.externalEventStateProvider = { (isPresented: true, isLocked: isLocked) }
        var accessibilityCalls = 0
        var windowCalls = 0
        let clickedLocation = NSPoint(x: 240, y: 180)
        let targetFrame = NSRect(x: 100, y: 100, width: 400, height: 300)
        controller.externalClickAccessibilityTargetProvider = { location in
            accessibilityCalls += 1
            XCTAssertEqual(location, clickedLocation)
            return FloatingPanelAccessibilityTarget(
                window: AXUIElementCreateApplication(4242),
                ownerPID: 4242,
                ownerBundleID: "test.target",
                ownerName: "Target",
                title: "Document",
                frame: targetFrame
            )
        }
        controller.externalClickVisibleWindowsProvider = {
            windowCalls += 1
            return []
        }

        controller.recordExternalMouseClick(at: clickedLocation)

        XCTAssertEqual(controller.lastExternalClickLocation, clickedLocation)
        XCTAssertNotNil(controller.lastExternalClickAt)
        XCTAssertEqual(accessibilityCalls, 0)
        XCTAssertEqual(windowCalls, 0)

        isLocked = true
        let panel = NSPanel(contentRect: NSRect(x: 500, y: 400, width: 120, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let anchor = controller.currentAnchor(for: panel)

        XCTAssertEqual(accessibilityCalls, 1)
        XCTAssertEqual(windowCalls, 0)
        XCTAssertEqual(anchor?.ownerPID, 4242)
        XCTAssertEqual(anchor?.windowTitle, "Document")
    }

    func testQueuedClickAfterCloseDoesNotMutateRecentClickState() {
        let controller = FloatingTokenPanelController()
        let originalLocation = NSPoint(x: 12, y: 34)
        let originalDate = Date(timeIntervalSince1970: 123)
        controller.lastExternalClickLocation = originalLocation
        controller.lastExternalClickAt = originalDate

        controller.recordExternalMouseClick(at: NSPoint(x: 800, y: 600))

        XCTAssertEqual(controller.lastExternalClickLocation, originalLocation)
        XCTAssertEqual(controller.lastExternalClickAt, originalDate)
    }

    func testFollowAccessibilityFrameResolutionIsOffMainActorAndSingleFlight() async throws {
        let resolvedFrame = NSRect(x: 120, y: 80, width: 640, height: 480)
        let probe = BlockingAccessibilityFrameQuery(result: resolvedFrame)
        let controller = FloatingTokenPanelController()
        controller.accessibilityResolver = FloatingPanelAccessibilityResolver(
            frameQuery: probe.query
        )
        controller.relaxedVisibleWindowCache = FloatingPanelWindowListCache(
            createdAt: Date(),
            windows: []
        )
        let accessibilityWindow = AXUIElementCreateApplication(987_654)
        let anchor = FloatingPanelWindowAnchor(
            windowNumber: nil,
            ownerPID: 987_654,
            ownerBundleID: "test.target",
            windowTitle: "Document",
            targetDescription: "Target · Document",
            offset: .zero,
            accessibilityWindow: accessibilityWindow
        )
        controller.lockedAnchor = anchor

        let startedAt = ContinuousClock.now
        XCTAssertNil(controller.targetFrame(matching: anchor))
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .milliseconds(100),
            "阻塞中的 AX 查询不能占住 MainActor"
        )
        XCTAssertNil(controller.targetFrame(matching: anchor))
        XCTAssertTrue(probe.waitUntilStarted(timeout: 1))
        XCTAssertEqual(probe.callCount, 1, "同一时刻只允许一个 AX frame 查询")

        probe.release()
        let didResolve = await waitUntil {
            controller.cachedFollowAccessibilityFrame?.frame == resolvedFrame
        }
        XCTAssertTrue(didResolve)
        XCTAssertEqual(controller.targetFrame(matching: anchor)?.frame, resolvedFrame)
    }

    func testStaleFollowAccessibilityFrameCannotReplaceNewAnchorState() async {
        let probe = BlockingAccessibilityFrameQuery(
            result: NSRect(x: 20, y: 30, width: 400, height: 300)
        )
        let controller = FloatingTokenPanelController()
        controller.accessibilityResolver = FloatingPanelAccessibilityResolver(
            frameQuery: probe.query
        )
        controller.relaxedVisibleWindowCache = FloatingPanelWindowListCache(
            createdAt: Date(),
            windows: []
        )
        let anchor = FloatingPanelWindowAnchor(
            windowNumber: nil,
            ownerPID: 987_653,
            ownerBundleID: "test.old-target",
            windowTitle: "Old",
            targetDescription: "Old",
            offset: .zero,
            accessibilityWindow: AXUIElementCreateApplication(987_653)
        )
        controller.lockedAnchor = anchor

        XCTAssertNil(controller.targetFrame(matching: anchor))
        XCTAssertTrue(probe.waitUntilStarted(timeout: 1))
        controller.resetFollowTargetResolution()
        controller.lockedAnchor = nil
        probe.release()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.cachedFollowAccessibilityFrame)
    }

    func testBlockedWindowResolutionDoesNotDelayFrameResolution() async {
        let windowProbe = BlockingAccessibilityWindowQuery()
        let expectedFrame = NSRect(x: 12, y: 34, width: 560, height: 420)
        let resolver = FloatingPanelAccessibilityResolver(
            windowQuery: windowProbe.query,
            frameQuery: { _ in expectedFrame }
        )
        resolver.resolveTarget(
            matching: FloatingPanelAccessibilityWindowRequest(
                window: FloatingPanelTargetWindow(
                    windowNumber: 1,
                    ownerPID: 42,
                    ownerBundleID: "test.blocked",
                    ownerName: "Blocked",
                    title: "Blocked",
                    frame: .zero,
                    rawFrame: .zero
                ),
                displayMaxY: 900
            ),
            completion: { _ in }
        )
        XCTAssertTrue(windowProbe.waitUntilStarted(timeout: 1))

        var resolvedFrame: NSRect?
        resolver.resolveFrame(
            FloatingPanelAccessibilityFrameRequest(
                window: AXUIElementCreateApplication(43),
                ownerPID: 43,
                displayMaxY: 900
            )
        ) { frame in
            resolvedFrame = frame
        }

        let didResolve = await waitUntil {
            resolvedFrame == expectedFrame
        }
        windowProbe.release()
        XCTAssertTrue(didResolve, "慢窗口匹配不能堵住逐帧跟随通道")
    }

    func testPointResolutionCoalescesBurstToRunningAndLatestRequest() async {
        let probe = BlockingAccessibilityPointQuery()
        let resolver = FloatingPanelAccessibilityResolver(pointQuery: probe.query)
        let staleCompletion = expectation(description: "stale completion")
        staleCompletion.isInverted = true
        let middleCompletion = expectation(description: "middle completion")
        middleCompletion.isInverted = true
        let latestCompletion = expectation(description: "latest completion")

        resolver.resolveTarget(
            at: FloatingPanelAccessibilityPointRequest(
                location: CGPoint(x: 1, y: 0),
                displayMaxY: 900
            )
        ) { _ in
            staleCompletion.fulfill()
        }
        XCTAssertTrue(probe.waitUntilStarted(timeout: 1))
        resolver.resolveTarget(
            at: FloatingPanelAccessibilityPointRequest(
                location: CGPoint(x: 2, y: 0),
                displayMaxY: 900
            )
        ) { _ in
            middleCompletion.fulfill()
        }
        resolver.resolveTarget(
            at: FloatingPanelAccessibilityPointRequest(
                location: CGPoint(x: 3, y: 0),
                displayMaxY: 900
            )
        ) { _ in
            latestCompletion.fulfill()
        }
        probe.release()

        await fulfillment(
            of: [latestCompletion, staleCompletion, middleCompletion],
            timeout: 1
        )
        XCTAssertEqual(probe.locations, [1, 3])
    }

    func testAccessibilityObserverInstallationRunsOffMainActor() async {
        let probe = BlockingAccessibilityObserverInstall()
        let resolver = FloatingPanelAccessibilityObserverResolver(
            installOperation: probe.install
        )
        var didComplete = false
        let startedAt = ContinuousClock.now
        resolver.install(
            FloatingPanelAccessibilityObserverRequest(
                ownerPID: 99,
                window: AXUIElementCreateApplication(99),
                context: FloatingPanelAccessibilityObserverContext {}
            )
        ) { _ in
            didComplete = true
        }
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .milliseconds(100),
            "AXObserver 注册不能占住 MainActor"
        )
        XCTAssertTrue(probe.waitUntilStarted(timeout: 1))
        XCTAssertFalse(probe.ranOnMainThread)

        probe.release()
        let completed = await waitUntil { didComplete }
        XCTAssertTrue(completed)
    }

    func testAccessibilityIPCUsesBoundedMessagingTimeout() {
        XCTAssertEqual(FloatingPanelAccessibilityIPC.messagingTimeout, 0.25)
        XCTAssertEqual(FloatingPanelAccessibilityIPC.windowResolutionBudget, 0.75)
    }

    func testMainActorFloatingPanelFilesContainNoSynchronousAccessibilityReads() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainActorFiles = [
            "Sources/CodexTokenBar/FloatingTokenPanel+WindowFollow.swift",
            "Sources/CodexTokenBar/FloatingTokenPanel+WindowTargeting.swift"
        ]
        for path in mainActorFiles {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("AXUIElementCopy"), "\(path) 不能重新引入同步 AX 读取")
            XCTAssertFalse(source.contains("AXObserverAddNotification"), "\(path) 不能在 MainActor 注册 AXObserver")
            XCTAssertFalse(source.contains("AXObserverRemoveNotification"), "\(path) 不能在 MainActor 移除 AXObserver")
        }
        let resolverSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/CodexTokenBar/FloatingPanelAccessibilityResolver.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(resolverSource.contains("AXUIElementSetMessagingTimeout"))
        XCTAssertTrue(resolverSource.contains("queue.async"))
        let observerResolverSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/CodexTokenBar/FloatingPanelAccessibilityObserverResolver.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(observerResolverSource.contains("AXObserverAddNotification"))
        XCTAssertTrue(observerResolverSource.contains("AXObserverRemoveNotification"))
        XCTAssertTrue(observerResolverSource.contains("queue.async"))
    }

    private func makePanel() -> FloatingTokenPanelWindow {
        FloatingTokenPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 258, height: 97),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private final class BlockingAccessibilityFrameQuery: @unchecked Sendable {
    private let condition = NSCondition()
    private let result: NSRect?
    private var calls = 0
    private var isReleased = false

    init(result: NSRect?) {
        self.result = result
    }

    var query: FloatingPanelAccessibilityResolver.FrameQuery {
        { [self] _ in
            condition.lock()
            calls += 1
            condition.broadcast()
            while !isReleased {
                condition.wait()
            }
            condition.unlock()
            return result
        }
    }

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while calls == 0 {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BlockingAccessibilityWindowQuery: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var isReleased = false

    var query: FloatingPanelAccessibilityResolver.WindowQuery {
        { [self] _ in
            condition.lock()
            calls += 1
            condition.broadcast()
            while !isReleased {
                condition.wait()
            }
            condition.unlock()
            return nil
        }
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while calls == 0 {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BlockingAccessibilityPointQuery: @unchecked Sendable {
    private let condition = NSCondition()
    private var recordedLocations: [CGFloat] = []
    private var isReleased = false

    var query: FloatingPanelAccessibilityResolver.PointQuery {
        { [self] request in
            condition.lock()
            recordedLocations.append(request.location.x)
            condition.broadcast()
            while recordedLocations.count == 1, !isReleased {
                condition.wait()
            }
            condition.unlock()
            return nil
        }
    }

    var locations: [CGFloat] {
        condition.lock()
        defer { condition.unlock() }
        return recordedLocations
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while recordedLocations.isEmpty {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BlockingAccessibilityObserverInstall: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var onMainThread = false
    private var isReleased = false

    var install: FloatingPanelAccessibilityObserverResolver.InstallOperation {
        { [self] _ in
            condition.lock()
            started = true
            onMainThread = Thread.isMainThread
            condition.broadcast()
            while !isReleased {
                condition.wait()
            }
            condition.unlock()
            return nil
        }
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return onMainThread
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !started {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
