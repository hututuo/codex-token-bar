import XCTest
import SwiftUI
import AppKit
@testable import CodexTokenBar

final class BodySpeedDistributionPreviewTests: XCTestCase {
    @MainActor
    func testRealDataProductPreview() throws {
        guard let inputPath = ProcessInfo.processInfo.environment["CODEX_DISTRIBUTION_PREVIEW_INPUT"],
              let output = ProcessInfo.processInfo.environment["CODEX_DISTRIBUTION_PREVIEW_OUTPUT"] else {
            throw XCTSkip("Opt-in product rendering from sanitized numeric fixture")
        }
        struct Marker: Decodable { let observedAt: Double; let previousAt: Double }
        struct Fixture: Decodable { let now: Double; let points: [BodySpeedTrendPoint]; let resetMarkers: [Marker] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
        let points = try BodySpeedTrendStore.distributions(fixture.points, width: 1800, completedThrough: Int64(fixture.now))
        XCTAssertFalse(points.isEmpty)
        let marker = fixture.resetMarkers.map { BodySpeedResetMarker(observedAt: Date(timeIntervalSince1970: $0.observedAt), previousAt: Date(timeIntervalSince1970: $0.previousAt)) }
        let input = BodySpeedTrendInput(points: points, days: 1, windowSeconds: 86400,
            preferredModels: ["gpt-6.1-sol"], minute: Int64(fixture.now / 60), error: nil, resetMarkers: marker)
        let identity = NSObject()
        let content = VStack(alignment: .leading, spacing: 24) {
            Text("产品组件 · 本机真实历史数据").font(.system(size: 24, weight: .semibold))
            Text("10/22 05:00 — 10/23 05:00 · 6.1 Sol · \(fixture.points.reduce(0) { $0 + $1.sampleCount })段正文 · 蓝线为额度回升观测")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            BodySpeedTrendContent(input: input, compact: false, source: ObjectIdentifier(identity), selectWindow: { _ in })
                .padding(18).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            HStack(alignment: .top, spacing: 24) {
                Text("三级菜单\n同一组真实数据").font(.system(size: 18, weight: .semibold)).frame(width: 190, alignment: .leading)
                BodySpeedTrendContent(input: input, compact: true, source: ObjectIdentifier(identity), selectWindow: { _ in })
                    .padding(18).frame(width: 570).background(Color(red: 0.035, green: 0.045, blue: 0.04), in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(28).frame(width: 1100).background(Color(red: 0.94, green: 0.95, blue: 0.97)).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
        try JSONEncoder().encode(points).write(to: URL(fileURLWithPath: output + ".json"))
    }
}
