import AppKit
import QuartzCore
import XCTest
@testable import CodexTokenBar

final class MatchedStrokeMorphTests: XCTestCase {
    @MainActor func testGenericNonQuotaPathKeepsOwnershipAndNeverFadesThroughZero() throws {
        let registry = MatchedStrokeMorphRegistry(), source = NSView(), target = NSView()
        registry.register(UUID(), view: source, ids: ["any-widget"])
        registry.register(UUID(), view: target, ids: ["any-widget"])
        let view = MatchedStrokeMorphView()
        let a = MatchedStrokeMorphEndpoint(points: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 8), CGPoint(x: 30, y: 30)])
        let b = MatchedStrokeMorphEndpoint(points: [CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 15), CGPoint(x: 8, y: 30)], width: 4)
        let route = MatchedStrokeMorphRoute(id: "arbitrary-shape", participantID: "any-widget", expanded: a, collapsed: b, color: .magenta)
        func update(_ expanded: Bool) {
            view.update(expanded: expanded, enabled: true, participantCount: 1, registry: registry) { [route] }
        }
        update(true); update(false)
        XCTAssertEqual(registry.coveredViewCount, 2)
        XCTAssertEqual(view.morphLayerCount, 1)
        let shape = try XCTUnwrap(view.layer?.sublayers?.first as? CAShapeLayer)
        let animation = try XCTUnwrap(shape.animation(forKey: "matched-stroke") as? CAAnimationGroup)
        let opacity = try XCTUnwrap(animation.animations?.first { $0.keyPathIfProperty == "opacity" } as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(opacity.fromValue as? Double), 1)
        XCTAssertEqual(try XCTUnwrap(opacity.toValue as? Double), 1, "Matched graphics must not fade away at either endpoint")
        let closingPath = try XCTUnwrap(animation.animations?.first { $0.keyPathIfProperty == "path" } as? CABasicAnimation)
        var first = [Float](repeating: 0, count: 2), second = first
        closingPath.timingFunction?.getControlPoint(at: 1, values: &first)
        closingPath.timingFunction?.getControlPoint(at: 2, values: &second)
        XCTAssertEqual(first[0], 1.0 / 3, accuracy: 0.0001); XCTAssertEqual(first[1], 1)
        XCTAssertEqual(second[0], 2.0 / 3, accuracy: 0.0001); XCTAssertEqual(second[1], 1)
        XCTAssertEqual(MatchedStrokeMorphGeometry.vertices(shape.path)?.count, 3, "The renderer must support shapes other than the quota's 33-point arcs")
        update(true)
        let reversed = try XCTUnwrap(view.layer?.sublayers?.first as? CAShapeLayer)
        let group = try XCTUnwrap(reversed.animation(forKey: "matched-stroke") as? CAAnimationGroup)
        let widths = try XCTUnwrap(group.animations?.first { $0.keyPathIfProperty == "lineWidth" } as? CAKeyframeAnimation)
        XCTAssertEqual(try XCTUnwrap(widths.values?.first as? Double), 3, accuracy: 0.01)
        let path = try XCTUnwrap(group.animations?.first { $0.keyPathIfProperty == "path" } as? CAKeyframeAnimation)
        let startPaths = try XCTUnwrap(path.values as? [CGPath])
        let startPath = try XCTUnwrap(startPaths.first)
        XCTAssertEqual(MatchedStrokeMorphGeometry.vertices(startPath), a.points, "A reversal before first presentation must not flash the unpresented model destination")
        XCTAssertEqual(registry.coveredViewCount, 2, "Rapid reversal must not reveal the originals in between")
        view.clear()
        XCTAssertEqual(source.alphaValue, 1); XCTAssertEqual(target.alphaValue, 1)
        XCTAssertEqual(view.morphLayerCount, 0)
    }

    @MainActor func testRegistryCoversNewHostsAndDoesNotReleaseAnotherAnimationOwner() {
        let registry = MatchedStrokeMorphRegistry(), a = UUID(), b = UUID()
        let old = NSView(), replacement = NSView()
        registry.register(UUID(), view: old, ids: ["component"])
        registry.cover(["component"], owner: a)
        registry.register(UUID(), view: replacement, ids: ["component"])
        XCTAssertEqual(replacement.alphaValue, 0, "A data refresh must not flash a replacement native host during morph")
        registry.cover(["component"], owner: b)
        registry.cover([], owner: a)
        XCTAssertEqual(old.alphaValue, 0)
        registry.cover([], owner: b)
        XCTAssertEqual(old.alphaValue, 1); XCTAssertEqual(replacement.alphaValue, 1)
    }

    @MainActor func testInvalidPathsFallBackWithoutHidingParticipants() {
        let registry = MatchedStrokeMorphRegistry(), source = NSView()
        registry.register(UUID(), view: source, ids: ["bad"])
        let view = MatchedStrokeMorphView()
        let endpoint = MatchedStrokeMorphEndpoint(points: [.zero])
        let route = MatchedStrokeMorphRoute(id: "bad", participantID: "bad", expanded: endpoint, collapsed: endpoint, color: .red)
        view.update(expanded: true, enabled: true, participantCount: 1, registry: registry) { [route] }
        view.update(expanded: false, enabled: true, participantCount: 1, registry: registry) { [route] }
        XCTAssertEqual(view.morphLayerCount, 0); XCTAssertEqual(source.alphaValue, 1)
    }

    func testClosingPathIsStraightAt180MillisecondsAndHeightSettlesSeparately() {
        XCTAssertEqual(ClientQuotaMorphGeometry.closingDuration, 0.18)
        XCTAssertEqual(ClientQuotaMorphGeometry.settlingDuration, 0.12)
        XCTAssertEqual(MatchedStrokeMorphTiming.progress(0.18 / ClientQuotaMorphGeometry.closingDuration, expanding: false), 1)
    }
}

private extension CAAnimation {
    var keyPathIfProperty: String? { (self as? CAPropertyAnimation)?.keyPath }
}
