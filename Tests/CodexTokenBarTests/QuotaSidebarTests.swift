import XCTest
@testable import CodexTokenBar

final class QuotaSidebarTests: XCTestCase {
    func testCacheReminderRevealsSummaryUntilClearedAndPreservesPinnedDetails() {
        var state = QuotaSidebarInteraction()
        state.presentCacheAdvice("a:100")
        XCTAssertTrue(state.expanded)
        XCTAssertNil(state.detail)
        XCTAssertFalse(state.pinned)
        state.leaveAfterGrace()
        XCTAssertTrue(state.expanded)
        state.presentCacheAdvice(nil)
        state.leaveAfterGrace()
        XCTAssertFalse(state.expanded)
        state.select(.tasks)
        state.togglePin()
        state.presentCacheAdvice("a:101")
        XCTAssertEqual(state.detail, .tasks)
        XCTAssertTrue(state.pinned)
        state.presentCacheAdvice(nil)
        state.leaveAfterGrace()
        XCTAssertEqual(state.detail, .tasks)
        state.presentCacheAdvice("a:102")
        state.beginDrag()
        XCTAssertNil(state.cacheNoticeID)
        state.presentCacheAdvice("a:103")
        state.dismiss()
        XCTAssertEqual(state, QuotaSidebarInteraction())
    }

    @MainActor
    func testDetailSectionSelectionCanRepeatAndTabSelectionReturnsToTop() {
        let controller = QuotaSidebarController()
        controller.select(.credits)
        XCTAssertEqual(controller.interaction.detail, .credits)
        XCTAssertEqual(controller.detailScrollTarget, "top")
        let revision = controller.detailScrollRevision
        controller.select(.credits)
        XCTAssertEqual(controller.detailScrollRevision, revision + 1)
        controller.select(.overview, section: "models")
        XCTAssertEqual(controller.detailScrollTarget, "models")
        controller.select(.tasks)
        XCTAssertEqual(controller.detailScrollTarget, "top")
        XCTAssertEqual(controller.interaction.detail, .tasks)
    }

    func testRateRibbonUsesLiveOutputAndConfiguredScale() {
        let fraction = QuotaSidebarRatePresentation.fraction
        XCTAssertEqual(fraction(0, 200, true), 0)
        XCTAssertEqual(fraction(100, 200, true), 0.5)
        XCTAssertEqual(fraction(500, 200, true), 1)
        XCTAssertEqual(fraction(-1, 200, true), 0)
        XCTAssertEqual(fraction(.nan, 200, true), 0)
        XCTAssertEqual(fraction(.infinity, 200, true), 0)
        XCTAssertEqual(fraction(75, .nan, true), 0.5)
        XCTAssertEqual(fraction(100, 200, false), 0)
    }

    func testSettingsDefaultOnAndIndependentFromFloating() {
        let suite = "QuotaSidebarTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "floatingPanelEnabled")
        XCTAssertEqual(QuotaSidebarSettings.load(defaults: defaults), .init())
        defaults.set(true, forKey: QuotaSidebarSettings.enabledKey)
        defaults.set("left", forKey: QuotaSidebarSettings.edgeKey)
        XCTAssertEqual(QuotaSidebarSettings.load(defaults: defaults), .init(enabled: true, edge: .left))
        defaults.set("invalid", forKey: QuotaSidebarSettings.edgeKey)
        XCTAssertEqual(QuotaSidebarSettings.load(defaults: defaults).edge, .right)
        XCTAssertTrue(defaults.bool(forKey: "floatingPanelEnabled"))
        defaults.set(false, forKey: QuotaSidebarSettings.enabledKey)
        XCTAssertFalse(QuotaSidebarSettings.load(defaults: defaults).enabled)
    }

    func testHoverNeverOpensDetailAndPinSurvivesGrace() {
        var state = QuotaSidebarInteraction()
        state.enter()
        XCTAssertTrue(state.expanded)
        XCTAssertNil(state.detail)
        state.togglePin()
        XCTAssertTrue(state.pinned)
        state.leaveAfterGrace()
        XCTAssertTrue(state.expanded)
        XCTAssertNil(state.detail)
        state.togglePin()
        state.leaveAfterGrace()
        XCTAssertFalse(state.expanded)
        state.select(.tasks)
        state.togglePin()
        state.leaveAfterGrace()
        XCTAssertEqual(state.detail, .tasks)
        state.dismiss()
        XCTAssertEqual(state, QuotaSidebarInteraction())
    }

    func testGeometryKeepsCenterAndEdgeOnOffsetScaledDisplay() {
        let area = CGRect(x: -1920, y: 35, width: 1920, height: 1045)
        for edge in QuotaSidebarEdge.allCases {
            let compact = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: false, scale: 2)
            let expanded = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true, scale: 2)
            XCTAssertEqual(compact.rail.width, 16)
            XCTAssertEqual(expanded.rail.width, 88)
            XCTAssertEqual(compact.rail.midY, expanded.rail.midY)
            XCTAssertEqual(expanded.detail.midY, expanded.rail.midY)
            XCTAssertTrue(area.contains(expanded.rail))
            XCTAssertTrue(area.contains(expanded.detail))
            XCTAssertEqual(edge == .left ? compact.rail.minX : compact.rail.maxX,
                           edge == .left ? expanded.rail.minX : expanded.rail.maxX)
            XCTAssertEqual(edge == .left ? expanded.detail.minX - expanded.rail.maxX : expanded.rail.minX - expanded.detail.maxX, 12)
        }
    }

    func testSpringGrowsHeightContinuouslyAroundPinnedEdgeAndSettlesExactly() {
        for edge in QuotaSidebarEdge.allCases {
            let area = CGRect(x: 100, y: 40, width: 1200, height: 900)
            let compact = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: false)
            let expanded = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true)
            for (current, target) in [(compact.rail, expanded.rail), (expanded.rail, compact.rail)] {
                let opening = target.height > current.height
                let sample = { (t: Double) in QuotaSidebarMotion.frame(from: current, to: target,
                    time: t, expanding: opening, edge: edge, area: area, scale: 2) }
                XCTAssertEqual(sample(0), current)
                XCTAssertEqual(sample(1), target)
                let middle = sample(0.1)
                XCTAssertNotEqual(middle.height, current.height)
                XCTAssertNotEqual(middle.height, target.height)
                XCTAssertEqual(middle.midY, current.midY, accuracy: 0.5)
                XCTAssertEqual(edge == .left ? middle.minX : middle.maxX,
                               edge == .left ? target.minX : target.maxX)
            }
        }
    }

    func testExpansionIsMonotonicAndClampedOnFractionalScreens() {
        let values = (0...100).map { QuotaSidebarMotion.progress(Double($0) / 100, expanding: true) }
        XCTAssertEqual(values.max()!, 1)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        for edge in QuotaSidebarEdge.allCases {
            for scale in [CGFloat(1), 1.5, 2] {
                let area = CGRect(x: -700.3, y: 22.7, width: 700.4, height: 375.5)
                let start = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: false, scale: scale, normalizedY: 0.97).rail
                let end = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true, scale: scale, normalizedY: 0.97).rail
                for i in 0...100 {
                    let frame = QuotaSidebarMotion.frame(from: start, to: end, time: Double(i) / 100,
                        expanding: true, edge: edge, area: area, scale: scale)
                    XCTAssertTrue(area.contains(frame))
                }
            }
        }
    }

    func testReversingAnimationStartsFromActualIntermediateFrame() {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let compact = QuotaSidebarFrames.make(usableFrame: area, edge: .right, expanded: false).rail
        let expanded = QuotaSidebarFrames.make(usableFrame: area, edge: .right, expanded: true).rail
        let interrupted = QuotaSidebarMotion.frame(from: compact, to: expanded, time: 0.15,
            expanding: true, edge: .right, area: area, scale: 1)
        XCTAssertEqual(QuotaSidebarMotion.frame(from: interrupted, to: compact, time: 0,
            expanding: false, edge: .right, area: area, scale: 1), interrupted)
        XCTAssertEqual(QuotaSidebarMotion.frame(from: interrupted, to: compact, time: 1,
            expanding: false, edge: .right, area: area, scale: 1), compact)
    }

    func testDockSnapUsesContinuousBoundedEaseOutFromReleasedFrame() {
        for edge in QuotaSidebarEdge.allCases {
            let area = CGRect(x: -1200, y: 30, width: 1200, height: 850)
            let target = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true).rail
            let released = target.offsetBy(dx: edge == .left ? 100 : -100, dy: 20)
            let sample = { (t: Double) in QuotaSidebarMotion.snapFrame(from: released, to: target,
                time: t, area: area, scale: 2) }
            XCTAssertEqual(sample(0), released)
            XCTAssertEqual(sample(1), target)
            XCTAssertNotEqual(sample(0.5), target)
            XCTAssertLessThan(abs(sample(0.5).minX - target.minX), 50)
            for i in 0...100 { XCTAssertTrue(area.contains(sample(Double(i) / 100))) }
        }
    }

    func testPartlyOffscreenDockStartsAtReleaseInsteadOfClampingFirstTick() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = QuotaSidebarFrames.make(usableFrame: area, edge: .right, expanded: true).rail
        let released = target.offsetBy(dx: 40, dy: -10)
        let early = QuotaSidebarMotion.snapFrame(from: released, to: target, time: 0.01, area: area, scale: 2)
        XCTAssertGreaterThan(early.maxX, area.maxX)
        XCTAssertLessThan(abs(early.minX - released.minX), 2)
        XCTAssertEqual(QuotaSidebarMotion.snapFrame(from: released, to: target, time: 1, area: area, scale: 2), target)
    }

    func testFractionalDisplayOriginsNeverCrossUsableBounds() {
        let area = CGRect(x: -100.3, y: 32.7, width: 1199.4, height: 893.2)
        for edge in QuotaSidebarEdge.allCases {
            for scale in [CGFloat(1), 1.5, 2] {
                let frames = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true, scale: scale)
                XCTAssertTrue(area.contains(frames.rail))
                XCTAssertTrue(area.contains(frames.detail))
                XCTAssertEqual(frames.rail.minX * scale, (frames.rail.minX * scale).rounded(), accuracy: 0.0001)
            }
        }
    }

    func testMissingFiveHourShortensBothLayersWithoutMovingCenterOrDetail() {
        let area = CGRect(x: -1920, y: 35, width: 1920, height: 1045)
        for edge in QuotaSidebarEdge.allCases {
            for expanded in [false, true] {
                let full = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: expanded, scale: 2, hasFiveHour: true)
                let weekly = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: expanded, scale: 2, hasFiveHour: false)
                XCTAssertEqual(full.rail.height, expanded ? 560 : 250)
                XCTAssertEqual(weekly.rail.height, expanded ? 470 : 192)
                XCTAssertEqual(weekly.rail.midY, full.rail.midY)
                XCTAssertEqual(weekly.rail.minX, full.rail.minX)
                XCTAssertEqual(weekly.rail.width, full.rail.width)
                XCTAssertEqual(weekly.detail, full.detail)
            }
        }
    }

    @MainActor
    func testQuotaPresenceRefreshPreservesPinnedDetailAndDoesNotInventFiveHour() {
        let controller = QuotaSidebarController()
        let fiveHour = AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: nil)
        let week = AccountQuotaWindow(label: "7d", usedPercent: 40, resetsAt: nil)
        controller.updateQuotaSnapshot(.init(fiveHour: fiveHour, sevenDay: week))
        XCTAssertTrue(controller.hasFiveHour)
        controller.select(.tasks)
        controller.togglePin()
        let pinned = controller.interaction
        // Even unavailable / nil data must remove the item. Do not preserve a
        // made-up 5h placeholder from a previous account snapshot.
        controller.updateQuotaSnapshot(.init(sevenDay: week))
        XCTAssertFalse(controller.hasFiveHour)
        XCTAssertEqual(controller.interaction, pinned)
        controller.updateQuotaSnapshot(.empty)
        XCTAssertFalse(controller.hasFiveHour)
        XCTAssertEqual(controller.interaction, pinned)
        controller.updateQuotaSnapshot(.init(fiveHour: fiveHour, sevenDay: week))
        XCTAssertTrue(controller.hasFiveHour)
        XCTAssertEqual(controller.interaction, pinned)
        controller.close()
    }

    func testSmallDisplayClampsNativeWindows() {
        let area = CGRect(x: 0, y: 0, width: 250, height: 240)
        for edge in QuotaSidebarEdge.allCases {
            let frames = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true, scale: 1)
            XCTAssertTrue(area.contains(frames.rail))
            XCTAssertTrue(area.contains(frames.detail))
            XCTAssertEqual(frames.detail.width, 150)
            XCTAssertEqual(frames.detail.height, 240)
        }
    }

    func testUnionIncludesCrossingGapOnlyWhileDetailVisible() {
        for edge in QuotaSidebarEdge.allCases {
            let frames = QuotaSidebarFrames.make(usableFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), edge: edge, expanded: true)
            let point = CGPoint(x: edge == .left ? frames.rail.maxX + 6 : frames.rail.minX - 6, y: frames.rail.midY)
            XCTAssertFalse(frames.contains(point, detailVisible: false))
            XCTAssertTrue(frames.contains(point, detailVisible: true))
            XCTAssertFalse(frames.contains(CGPoint(x: point.x, y: 20), detailVisible: true))
        }
    }

    func testUnknownAndExpiredQuotaAreNotFreshZero() {
        let now = Date(timeIntervalSince1970: 10000)
        let unknown = QuotaSidebarQuotaPresentation.make(window: nil, snapshot: .empty, now: now)
        XCTAssertNil(unknown.remaining)
        XCTAssertEqual(unknown.text, "未知")
        let window = AccountQuotaWindow(label: "5h", usedPercent: 28, resetsAt: now.addingTimeInterval(-1))
        let expired = QuotaSidebarQuotaPresentation.make(window: window, snapshot: .init(fiveHour: window, updatedAt: now), now: now)
        XCTAssertEqual(expired.remaining, 72)
        XCTAssertTrue(expired.stale)
        let freshWindow = AccountQuotaWindow(label: "5h", usedPercent: 28, resetsAt: now.addingTimeInterval(3600))
        let fresh = QuotaSidebarQuotaPresentation.make(window: freshWindow, snapshot: .init(fiveHour: freshWindow, updatedAt: now), now: now)
        XCTAssertFalse(fresh.stale)
        let stale = QuotaSidebarQuotaPresentation.make(window: freshWindow, snapshot: .init(fiveHour: freshWindow, updatedAt: now.addingTimeInterval(-901)), now: now)
        XCTAssertTrue(stale.stale)
    }

    func testModelSharesUseAllMeasuredModelsBeforeTopFourTruncation() {
        let snapshot = Self.modelSnapshot(rows: [Self.modelRow("A", 300), Self.modelRow("A", 100),
                                               Self.modelRow("B", 200), Self.modelRow("C", 100),
                                               Self.modelRow("D", 80), Self.modelRow("E", 20),
                                               Self.modelRow("placeholder", 0)])
        let items = QuotaSidebarModelUsage.items(snapshot: snapshot)
        XCTAssertEqual(items.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(items.map(\.tokens), [400, 200, 100, 80])
        XCTAssertEqual(items[0].share, 0.5, accuracy: 0.00001)
        XCTAssertEqual(items.reduce(0) { $0 + $1.share }, 0.975, accuracy: 0.00001)
    }

    func testModelBreakdownDoesNotInventRowsWhenUntrustedOrEmpty() {
        let row = Self.modelRow("actual-model", 200)
        XCTAssertTrue(QuotaSidebarModelUsage.items(snapshot: Self.modelSnapshot(rows: [])).isEmpty)
        XCTAssertTrue(QuotaSidebarModelUsage.items(snapshot: Self.modelSnapshot(rows: [row], precision: .metadataOnly)).isEmpty)
        let unknown = QuotaSidebarModelUsage.items(snapshot: Self.modelSnapshot(rows: [Self.modelRow(nil, 200)]))
        XCTAssertEqual(unknown.count, 1)
        XCTAssertEqual(unknown.first?.label, "未知模型")
        XCTAssertEqual(unknown.first?.tokens, 200)
    }

    func testRichDetailUsesAvailableDisplaySpaceAndClampsSmallerScreens() {
        let large = QuotaSidebarFrames.make(usableFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000), edge: .right, expanded: true)
        XCTAssertEqual(large.detail.width, 420)
        XCTAssertEqual(large.detail.height, 600)
        XCTAssertEqual(large.detail.midY, large.rail.midY)
        let small = QuotaSidebarFrames.make(usableFrame: CGRect(x: 0, y: 0, width: 450, height: 480), edge: .left, expanded: true)
        XCTAssertEqual(small.detail.width, 350)
        XCTAssertEqual(small.detail.height, 480)
    }

    private static func modelRow(_ model: String?, _ tokens: Int) -> ModelTokenBreakdown {
        ModelTokenBreakdown(model: model, breakdown: TokenCacheBreakdown(inputTokens: tokens,
            cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: tokens, calls: 1))
    }

    private static func modelSnapshot(rows: [ModelTokenBreakdown], precision: DashboardUsagePrecision = .precise) -> TokenDisplaySnapshot {
        TokenDisplaySnapshot(title: "test", status: "", rate: 0, consumedTokens: 800, todayTokens: 800,
                             todayRequests: 6, todayModelBreakdowns: rows, usagePrecision: precision,
                             quota: .empty, updatedAt: Date())
    }

    func testRadarRankingHasAtMostEightRealEligibleRows() {
        let rows = (0..<10).map { index in
            CodexCrowdRadarModel(model: "model-\(index)", effort: "high", graded: 50, passed: 50 - index,
                                 passRate: Double(50 - index) / 50, cells: 50)
        } + [CodexCrowdRadarModel(model: "too-small", effort: "high", graded: 44, passed: 44, passRate: 1, cells: 44)]
        let crowd = CodexCrowdRadarSnapshot(generatedAt: "", taskCount: 0, cellCount: 0,
                                           contributorCount: 0, pendingGrades: 0, errorGrades: 0, models: rows)
        let ranks = QuotaSidebarRadarPresentation.rankedModels(crowd)
        XCTAssertEqual(ranks.count, 8)
        XCTAssertEqual(ranks.map(\.model), (0..<8).map { "model-\($0)" })
        XCTAssertTrue(QuotaSidebarRadarPresentation.rankedModels(nil).isEmpty)
        let unavailable = CodexCrowdRadarSnapshot(generatedAt: "", taskCount: 0, cellCount: 0,
            contributorCount: 0, pendingGrades: 0, errorGrades: 0, models: rows, realtimeAvailable: false)
        XCTAssertTrue(QuotaSidebarRadarPresentation.rankedModels(unavailable).isEmpty)
    }

    @MainActor
    func testCanvasContentStaysAtOneScreenPositionWhileNativeClipExpands() async {
        for edge in QuotaSidebarEdge.allCases {
            let host = NSView(frame: .zero)
            let canvas = QuotaSidebarCanvasView(host: host, edge: edge)
            for (width, height) in [(16.0, 134.0), (28.0, 220.0), (55.0, 350.0), (88.0, 470.0)] {
                let x = edge == .right ? 1440 - width : 0
                canvas.frame = CGRect(x: x, y: 600 - height / 2, width: width, height: height)
                canvas.layout()
                XCTAssertEqual(host.frame.size, CGSize(width: 88, height: 560))
                XCTAssertEqual(canvas.frame.minX + host.frame.minX, edge == .right ? 1352 : 0)
                XCTAssertEqual(canvas.frame.minY + host.frame.minY, 320)
                XCTAssertTrue(canvas.layer?.masksToBounds == true)
            }
        }
    }

    func testExpandedButtonRowsReceiveOriginalMouseSequence() {
        let size = CGSize(width: 88, height: 470)
        for y in stride(from: 15.0, through: 435.0, by: 20) {
            XCTAssertFalse(QuotaSidebarPressRouting.shouldTrackDrag(expanded: true, point: CGPoint(x: 44, y: y), size: size))
        }
        XCTAssertTrue(QuotaSidebarPressRouting.shouldTrackDrag(expanded: true, point: CGPoint(x: 44, y: 460), size: size))
        XCTAssertTrue(QuotaSidebarPressRouting.shouldTrackDrag(expanded: true, point: CGPoint(x: 2, y: 200), size: size))
        XCTAssertTrue(QuotaSidebarPressRouting.shouldTrackDrag(expanded: false, point: CGPoint(x: 8, y: 60), size: CGSize(width: 16, height: 134)))
    }

    func testRadarOpenFlagCannotOverrideWaitOrExpiredDeadline() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let waiting = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self,
            from: Data(#"{"recommendedAction":"wait","windowOpen":true,"window":{"open":true}}"#.utf8))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(waiting, stale: false, updatedAt: now, now: now))
        let expired = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self,
            from: Data(#"{"recommendedAction":"use window","windowOpen":true,"window":{"open":true,"countdownDeadline":"1970-01-01T02:46:40Z"}}"#.utf8))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(expired, stale: false, updatedAt: now, now: now))
        XCTAssertTrue(QuotaSidebarRadarPresentation.isActiveWindow(expired, stale: false, updatedAt: now.addingTimeInterval(-1), now: now.addingTimeInterval(-1)))
    }

    func testRadarLightRequiresFreshConfirmedOpenWindow() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let open = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self,
            from: Data(#"{"recommendedAction":"use window","windowOpen":true,"window":{"open":true}}"#.utf8))
        let waiting = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self,
            from: Data(#"{"windowOpen":false,"window":{"open":false}}"#.utf8))
        let conflicting = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self,
            from: Data(#"{"windowOpen":false,"window":{"open":true}}"#.utf8))
        XCTAssertTrue(QuotaSidebarRadarPresentation.isActiveWindow(open, stale: false, updatedAt: now, now: now))
        XCTAssertTrue(QuotaSidebarRadarPresentation.isActiveWindow(open, stale: false, updatedAt: now.addingTimeInterval(-899), now: now))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(open, stale: true, updatedAt: now, now: now))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(open, stale: false, updatedAt: nil, now: now))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(open, stale: false, updatedAt: now.addingTimeInterval(-901), now: now))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(waiting, stale: false, updatedAt: now, now: now))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(conflicting, stale: false, updatedAt: now, now: now))
        XCTAssertFalse(QuotaSidebarRadarPresentation.isActiveWindow(nil, stale: false, updatedAt: now, now: now))
        XCTAssertEqual(QuotaSidebarRadarPresentation.windowText(open), "速登窗口")
        XCTAssertEqual(QuotaSidebarRadarPresentation.windowText(waiting), "等待")
    }

    func testRadarEntryRemainsClickOnlyAndPreservesPinnedTab() {
        var state = QuotaSidebarInteraction()
        state.enter()
        XCTAssertNil(state.detail)
        state.select(.radar)
        state.togglePin()
        state.leaveAfterGrace()
        XCTAssertEqual(state.detail, .radar)
        XCTAssertTrue(state.pinned)
        XCTAssertEqual(QuotaSidebarRadarPresentation.windowText(nil), "雷达待读取")
    }

    func testNativeDragThresholdAndReanchoringAfterHoverResize() {
        var drag = QuotaSidebarDragSession(startPoint: CGPoint(x: 990, y: 400),
                                          startFrame: CGRect(x: 984, y: 330, width: 16, height: 134))
        XCTAssertNil(drag.update(to: CGPoint(x: 992, y: 402)))
        XCTAssertFalse(drag.didDrag)
        XCTAssertNotNil(drag.update(to: CGPoint(x: 980, y: 410)))
        let actualExpandedFrame = CGRect(x: 912, y: 280, width: 88, height: 250)
        drag.reanchor(point: CGPoint(x: 980, y: 410), frame: actualExpandedFrame)
        XCTAssertEqual(drag.update(to: CGPoint(x: 1000, y: 440)), actualExpandedFrame.offsetBy(dx: 20, dy: 30))
        XCTAssertTrue(drag.didDrag)
    }

    func testDraggedPlacementSelectsMonitorEdgeAndKeepsVerticalPosition() {
        let left = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let right = CGRect(x: 0, y: 0, width: 1512, height: 944)
        XCTAssertEqual(QuotaSidebarPlacement.nearestScreenIndex(to: CGPoint(x: -1500, y: 600), frames: [left, right]), 0)
        XCTAssertEqual(QuotaSidebarPlacement.nearestScreenIndex(to: CGPoint(x: 1600, y: 700), frames: [left, right]), 1)
        XCTAssertNil(QuotaSidebarPlacement.nearestScreenIndex(to: .zero, frames: []))
        XCTAssertEqual(QuotaSidebarPlacement.edge(at: CGPoint(x: -1700, y: 600), usableFrame: left), .left)
        XCTAssertEqual(QuotaSidebarPlacement.edge(at: CGPoint(x: -100, y: 600), usableFrame: left), .right)
        let fraction = QuotaSidebarPlacement.fraction(centerY: 600, usableFrame: left)
        for scale in [CGFloat(1), 2] {
            let frames = QuotaSidebarFrames.make(usableFrame: left, edge: .left, expanded: true,
                                                scale: scale, normalizedY: fraction)
            XCTAssertEqual(frames.rail.midY, 600, accuracy: 0.5)
            XCTAssertTrue(left.contains(frames.rail))
            XCTAssertTrue(left.contains(frames.detail))
        }
        let bottom = QuotaSidebarFrames.make(usableFrame: right, edge: .right, expanded: true, normalizedY: -1)
        let top = QuotaSidebarFrames.make(usableFrame: right, edge: .right, expanded: true, normalizedY: 2)
        XCTAssertEqual(bottom.rail.minY, right.minY)
        XCTAssertEqual(top.rail.maxY, right.maxY)
        XCTAssertTrue(right.contains(bottom.detail))
        XCTAssertTrue(right.contains(top.detail))
    }

    func testSidebarPlacementPersistsSeparatelyAndOverridesStaleEdgeReport() {
        let suite = "QuotaSidebarDragTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(QuotaSidebarPlacement.load(defaults: defaults))
        XCTAssertEqual(QuotaSidebarPlacement.resolvedEdge(requested: .right, defaults: defaults), .right)
        let placement = QuotaSidebarPlacement(displayID: 91, normalizedY: 0.72)
        placement.save(defaults: defaults)
        defaults.set("left", forKey: QuotaSidebarSettings.edgeKey)
        XCTAssertEqual(QuotaSidebarPlacement.load(defaults: defaults), placement)
        XCTAssertEqual(QuotaSidebarPlacement.resolvedEdge(requested: .right, defaults: defaults), .left)
        XCTAssertNil(defaults.object(forKey: "floatingPanelPosition"))
        var interaction = QuotaSidebarInteraction()
        interaction.select(.tasks)
        interaction.togglePin()
        interaction.beginDrag()
        XCTAssertTrue(interaction.expanded)
        XCTAssertNil(interaction.detail)
        XCTAssertFalse(interaction.pinned)
    }

    func testSidebarAloneOwnsCompactBackgroundWork() {
        XCTAssertTrue(DashboardBackgroundOwnerActivity.shouldRunExpensiveOwners(
            dashboardVisible: false, floatingPanelEnabled: false, statusBarPanelEnabled: false, quotaSidebarEnabled: true))
        XCTAssertTrue(DashboardBackgroundOwnerActivity.onlyCompactSurfaceVisible(
            dashboardVisible: false, floatingPanelEnabled: false, statusBarPanelEnabled: false,
            statusSummaryPresented: false, quotaSidebarEnabled: true))
        XCTAssertFalse(DashboardBackgroundOwnerActivity.onlyCompactSurfaceVisible(
            dashboardVisible: true, floatingPanelEnabled: false, statusBarPanelEnabled: false,
            statusSummaryPresented: false, quotaSidebarEnabled: true))
    }

    @MainActor
    func testSidebarConfigurationRetainsAppOwnerAfterDashboardCloses() {
        var starts = 0
        var stops = 0
        var active = [Bool]()
        let runtime = DashboardRuntime(
            notificationCenter: NotificationCenter(),
            automaticInterfaceScaleProvider: { 1 },
            dashboardVisibilityProvider: { false },
            startupAction: {}, surfaceApplyAction: { _ in },
            sideEffectStartAction: { starts += 1 }, sideEffectStopAction: { stops += 1 },
            backgroundOwnerActivityAction: { active.append($0) })
        let consumer = UUID()
        runtime.acquireConsumer(consumer)
        runtime.reportConfiguration(
            floatingPanelEnabled: false, statusBarPanelEnabled: false,
            floatingPanelVisibility: .default, floatingPanelLocked: false,
            preciseTokenCountingEnabled: false, providerSyncVisible: false, radarDetailsVisible: false,
            quotaSidebarEnabled: true, quotaSidebarEdge: .left, for: consumer)
        runtime.releaseConsumer(consumer)
        XCTAssertEqual(runtime.activeConsumerCount, 0)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(active.last, true)
        XCTAssertEqual(runtime.configuration?.quotaSidebarEdge, .left)
        let reopened = UUID()
        runtime.acquireConsumer(reopened)
        runtime.reportConfiguration(
            floatingPanelEnabled: false, statusBarPanelEnabled: false,
            floatingPanelVisibility: .default, floatingPanelLocked: false,
            preciseTokenCountingEnabled: false, providerSyncVisible: false, radarDetailsVisible: false,
            quotaSidebarEnabled: false, for: reopened)
        runtime.releaseConsumer(reopened)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(active.last, false)
    }
}
