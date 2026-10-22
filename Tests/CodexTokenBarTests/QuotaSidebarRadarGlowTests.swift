import AppKit
import XCTest
@testable import CodexTokenBar

@MainActor
final class QuotaSidebarRadarGlowTests: XCTestCase {
    func testRefreshDoesNotRestartCompositorMotionAndStoppingCancelsIt() {
        let view = QuotaSidebarRadarGlowView(frame: .init(x: 0, y: 0, width: 16, height: 582))
        view.configure(edge: .right, expanded: false)
        XCTAssertFalse(view.hasMotionAnimations)
        view.setMotionActive(true)
        let count = view.geometryApplicationCount
        for _ in 0..<100 { view.configure(edge: .right, expanded: false); view.setMotionActive(true) }
        XCTAssertEqual(view.geometryApplicationCount, count)
        XCTAssertEqual(view.animationStartCount, 1)
        XCTAssertTrue(view.hasMotionAnimations)
        view.setFrameSize(.init(width: 88, height: 625))
        view.configure(edge: .left, expanded: true)
        XCTAssertGreaterThan(view.geometryApplicationCount, count)
        XCTAssertEqual(view.animationStartCount, 1, "Resize/reposition does not restart the running animation")
        view.setMotionActive(false)
        XCTAssertFalse(view.hasMotionAnimations)
        view.setMotionActive(true)
        XCTAssertEqual(view.animationStartCount, 2)
        view.setMotionActive(false)
    }
    func testExpandedAndEdgeChangesKeepBorderInsideTheOriginalInputWindow() {
        let rect = CGRect(x: 0, y: 0, width: 88, height: 625)
        for edge in [QuotaSidebarEdge.left, .right] {
            let path = QuotaSidebarRadarGlowView.path(in: rect, radius: 22, edge: edge)
            XCTAssertEqual(path.boundingBoxOfPath, rect)
            XCTAssertTrue(path.contains(CGPoint(x: 44, y: 312)))
            XCTAssertFalse(path.contains(CGPoint(x: -1, y: 312)))
        }
    }
}
