import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class QuarteredQuotaRingTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Window: Decodable { let id: String; let window: String }
        struct Case: Decodable { let name: String; let remaining: [Double?] }
        let windows: [Window]; let cases: [Case]
        func items(_ amounts: [Double?]) -> [ClientQuotaItem] {
            zip(windows, amounts).map { window, amount in
                .init(id: window.id, client: "antigravity", window: window.window, remaining: amount,
                    resetsAt: nil, source: "模拟额度 · 不写入账本", status: amount == nil ? "未接入" : "", state: amount == nil ? "notConnected" : "available")
            }
        }
    }
    private func fixture() throws -> Fixture {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/quota-quarter-ring.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
    }

    func testFourAntigravityWindowsShareOneRingWithoutLosingIdentityOrHiddenChoices() throws {
        let fixture = try fixture(), items = fixture.items(fixture.cases[0].remaining)
        let group = try XCTUnwrap(ClientQuotaRingGroup.make(Array(items.reversed())).first)
        XCTAssertEqual(ClientQuotaRingGroup.make(items).count, 1)
        XCTAssertEqual(group.quarters.map(\.id), ClientQuotaQuarterLayout.ids)
        XCTAssertEqual(group.members, items)
        XCTAssertEqual(group.members.map(\.remaining), [85.12, 90.53, 0, nil])
        for hidden in items {
            var selection = ClientQuotaSelection(); selection.hidden.insert(hidden.id)
            let visible = items.filter(selection.includes)
            let fallback = ClientQuotaRingGroup.make(visible)
            XCTAssertTrue(fallback.allSatisfy { $0.quarters.isEmpty })
            XCTAssertEqual(fallback.flatMap(\.members), visible, "Hidden windows must not return as empty quarter placeholders")
        }
        XCTAssertTrue(ClientQuotaRingGroup.make(items, acrossClients: true).allSatisfy { $0.quarters.isEmpty })
    }

    @MainActor func testQuarteredQuotaPixelsKeepFourCleanJoinsAndSaveVerticalHeight() throws {
        let fixture = try fixture(), suite = "QuarteredQuotaPixels-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var selection = ClientQuotaSelection()
        selection.colors = Dictionary(uniqueKeysWithValues: fixture.windows.map { ($0.id, "#00ff00") })
        defaults.set(selection.encoded, forKey: ClientQuotaSelection.key)
        let scale = 8.0, center = CGPoint(x: 41, y: 37), radius = 27.0
        for sample in fixture.cases {
            let root = ClientQuarteredQuotaRing(items: fixture.items(sample.remaining))
                .frame(width: 74, height: 110, alignment: .top).padding(4).defaultAppStorage(defaults)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: root); renderer.scale = scale
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            func green(_ x: Double, _ y: Double) throws -> Bool {
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
                return color.alphaComponent > 0.5 && color.greenComponent > 0.5 && color.redComponent < 0.2 && color.blueComponent < 0.2
            }
            for angle in [0.0, Double.pi / 2, Double.pi, 3 * Double.pi / 2] {
                for offset in -2...2 {
                    let r = radius + Double(offset) / scale
                    XCTAssertFalse(try green(center.x + cos(angle) * r, center.y + sin(angle) * r), "\(sample.name): fixed quarter joins must not paint a cap dot")
                }
            }
            if sample.name == "zero" || sample.name == "unknown" {
                for degree in 0..<360 {
                    let angle = Double(degree) * Double.pi / 180
                    XCTAssertFalse(try green(center.x + cos(angle) * radius, center.y + sin(angle) * radius), "An empty/unknown window must never paint quota")
                }
            } else if sample.name == "full" {
                for degree in [45.0, 135, 225, 315] {
                    let angle = degree * Double.pi / 180
                    XCTAssertTrue(try green(center.x + cos(angle) * radius, center.y + sin(angle) * radius))
                }
            }
            if let folder = ProcessInfo.processInfo.environment["TOKENBAR_DISCOVERY_RENDER_DIR"] {
                let url = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("sidebar-quota-quarters-\(sample.name).png"))
            }
        }
        let items = fixture.items(fixture.cases[0].remaining)
        let compact = NSHostingView(rootView: ClientQuarteredQuotaRing(items: items).defaultAppStorage(defaults))
        let previous = NSHostingView(rootView: VStack(spacing: 7) {
            ClientPairedQuotaRing(left: items[0], right: items[1])
            ClientPairedQuotaRing(left: items[2], right: items[3])
        }.defaultAppStorage(defaults))
        XCTAssertLessThan(compact.fittingSize.height, previous.fittingSize.height - 50,
            "One quartered outline must actually save height at the production width")
    }

    @MainActor func testQuarteredQuotaMorphKeepsIndependentTracksAndSurvivesReversal() throws {
        let ring = CGRect(x: 20, y: 40, width: 54, height: 54)
        let registry = MatchedStrokeMorphRegistry(), expanded = NSView(), compact = NSView()
        let ids = Set(ClientQuotaQuarterLayout.ids)
        registry.register(UUID(), view: expanded, ids: ids); registry.register(UUID(), view: compact, ids: ids)
        let routes = (0..<4).map { quarter in
            ClientQuotaMorphRoute(id: ClientQuotaQuarterLayout.ids[quarter], ring: ring,
                track: CGRect(x: 6, y: Double(140 + quarter * 60), width: 4, height: 46), half: 0,
                fraction: Double(quarter + 1) / 4, color: .green, quarter: quarter)
        }
        let strokes = ClientQuotaMorphGeometry.strokes(routes)
        XCTAssertEqual(strokes.count, 8)
        XCTAssertEqual(Set(strokes.map(\.participantID)), ids)
        for (quarter, route) in routes.enumerated() {
            let fill = try XCTUnwrap(strokes.first { $0.id == route.id + ":quarter:fill" })
            XCTAssertEqual(fill.expanded.end - fill.expanded.start, Double(quarter + 1) / 4, accuracy: 0.0001)
            XCTAssertEqual(fill.expanded.clipPoints, fill.expanded.points)
            XCTAssertEqual(fill.clipLineCap, .butt)
            XCTAssertEqual(try XCTUnwrap(fill.collapsed.clipPoints?.first).y, route.track.maxY, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(fill.collapsed.clipPoints?.last).y, route.track.minY, accuracy: 0.0001)
            for progress in [0.0, 0.25, 0.5, 0.75, 1] {
                let points = ClientQuotaMorphGeometry.quarterPoints(ring: ring, track: route.track, quarter: quarter, progress: progress)
                XCTAssertEqual(points.count, 33)
                XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.y >= $1.y - 0.0001 }, "No quarter may turn over while becoming its own bar")
            }
        }
        let view = MatchedStrokeMorphView()
        for state in [false, true, false, true] {
            view.update(expanded: state, enabled: true, participantCount: 4, registry: registry) { strokes }
        }
        XCTAssertEqual(registry.coveredViewCount, 2)
        XCTAssertEqual(view.morphLayerCount, 8)
        view.clear()
        XCTAssertEqual(registry.coveredViewCount, 0)
        XCTAssertEqual(view.morphLayerCount, 0)
    }
}
