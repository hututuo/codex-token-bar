import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class HeatmapFlattenedRenderingTests: XCTestCase {
    @MainActor
    func testHeatmapFlatteningMatchesCellGridAtNativeAndRetinaScale() throws {
        let gradient = Gradient(stops: [.init(color: .red.opacity(0.8), location: 0),
            .init(color: .red.opacity(0.8), location: 0.35), .init(color: .blue.opacity(0.8), location: 0.35),
            .init(color: .blue.opacity(0.8), location: 1)])
        let gradientFill = AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
        let fills: [AnyShapeStyle] = [AnyShapeStyle(Color.red), AnyShapeStyle(Color.green.opacity(0.4)), gradientFill,
            AnyShapeStyle(Color.clear), AnyShapeStyle(Color.blue), gradientFill, AnyShapeStyle(Color.orange), AnyShapeStyle(Color.purple)]
        let columns = [Array(0..<7), [7]]
        for size: CGFloat in [10, 14.5] {
            let reference = HStack(alignment: .top, spacing: 4) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(columns[column][safe: row].flatMap { fills[safe: $0] } ?? AnyShapeStyle(Color.clear))
                                .frame(width: size, height: size)
                        }
                    }
                }
            }
            let actual = HeatmapCells(revision: UUID(), columns: columns, fills: fills, cellSize: size, gap: 4, rows: 7)
            for scale: CGFloat in [1, 2] {
                func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
                    renderer.scale = scale
                    return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                }
                let a = try render(actual), b = try render(reference)
                XCTAssertEqual(a.pixelsWide, b.pixelsWide); XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
                for x in 0..<a.pixelsWide { for y in 0..<a.pixelsHigh {
                    let ca = try XCTUnwrap(a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let cb = try XCTUnwrap(b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(ca.alphaComponent, cb.alphaComponent, accuracy: 3.0 / 255)
                    if max(ca.alphaComponent, cb.alphaComponent) > 0.05 {
                        XCTAssertEqual(ca.redComponent, cb.redComponent, accuracy: 4.0 / 255)
                        XCTAssertEqual(ca.greenComponent, cb.greenComponent, accuracy: 4.0 / 255)
                        XCTAssertEqual(ca.blueComponent, cb.blueComponent, accuracy: 4.0 / 255)
                    }
                }}
            }
        }
    }

    @MainActor
    func testLongModelIdentitiesKeepCompactCostCardExtent() throws {
        let labels = ["Flash3.8 · N", "Gemini Pro · 自动", "Auto Review (Luna)", "Argon4"]
        let items = labels.enumerated().map { offset, label in
            FloatingTodayModelUsageItem(id: "row\(offset)", label: label, tokens: 55_714_167,
                share: 0.001, costUSD: offset == 3 ? 204.23 : nil, usesIndependentQuota: false,
                referenceCostUSD: nil, color: .blue)
        }
        let grid = VStack(spacing: 6) {
            ForEach(items) { DashboardModelCostChip(item: $0, color: .blue).frame(width: 208) }
        }
        let host = NSHostingView(rootView: grid)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 208, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, 4 * 32 + 3 * 6)
        if let output = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            let renderer = ImageRenderer(content: grid.environment(\.colorScheme, .dark))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("model-identity-compact-cards.png"))
        }
    }
}
