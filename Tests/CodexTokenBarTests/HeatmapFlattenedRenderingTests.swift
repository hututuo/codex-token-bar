import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class HeatmapFlattenedRenderingTests: XCTestCase {
    @MainActor
    func testYearHeatmapLayoutKeepsAllCellsAndExactExtent() throws {
        // The largest production grid, including the last partial column.
        // A layout shortcut must not collapse, transpose or drop calendar cells.
        let columns = (0..<53).map { column in Array((column * 7)..<min(365, (column + 1) * 7)) }
        let colors: [Color] = [.red, .green, .blue]
        let fills = (0..<365).map { AnyShapeStyle(colors[$0 % 3]) }
        for size: CGFloat in [10, 14.5, 15.125] {
            let view = HeatmapCells(revision: UUID(), columns: columns, fills: fills, cellSize: size, gap: 4, rows: 7)
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
            let host = NSHostingView(rootView: view)
            let referenceHost = NSHostingView(rootView: reference)
            // AppKit rounds hosting extents to device pixels. Compare the
            // original production layout, not unrounded arithmetic.
            XCTAssertEqual(host.fittingSize, referenceHost.fittingSize)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let referenceRenderer = ImageRenderer(content: reference); referenceRenderer.scale = 2
            let expectedImage = NSBitmapImageRep(cgImage: try XCTUnwrap(referenceRenderer.cgImage))
            XCTAssertEqual(image.pixelsWide, expectedImage.pixelsWide)
            XCTAssertEqual(image.pixelsHigh, expectedImage.pixelsHigh)
            for index in 0..<371 {
                let x = Int((CGFloat(index / 7) * (size + 4) + size / 2) * 2)
                let y = Int((CGFloat(index % 7) * (size + 4) + size / 2) * 2)
                let pixel = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(pixel.alphaComponent, index < 365 ? 1 : 0, accuracy: 0.01)
                if index < 365 {
                    // Compare rendered pixels in the same color pipeline;
                    // dynamic SwiftUI colors differ from NSColor resolution.
                    let expected = try XCTUnwrap(expectedImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(pixel.redComponent, expected.redComponent, accuracy: 0.02)
                    XCTAssertEqual(pixel.greenComponent, expected.greenComponent, accuracy: 0.02)
                    XCTAssertEqual(pixel.blueComponent, expected.blueComponent, accuracy: 0.02)
                }
            }
        }
    }

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
        let labels = ["Astra6", "Sol5.6", "Opus5", "Flash3.8", "未知模型", "Auto Review (Luna)"]
        let items = labels.enumerated().map { offset, label in
            FloatingTodayModelUsageItem(id: offset == 4 ? "unknown-models" : "row\(offset)", label: label, tokens: 55_714_167,
                share: 0.001, costUSD: offset == 4 ? nil : 204.23, usesIndependentQuota: false,
                referenceCostUSD: offset == 4 ? 18.9 : nil, color: .blue,
                sourceModels: offset == 4 ? ["gemini-pro-default", "unknown"] : [])
        }
        let grid = VStack(spacing: 6) {
            ForEach(items) { DashboardModelCostChip(item: $0, color: .blue).frame(width: 360) }
        }
        let host = NSHostingView(rootView: grid)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 360, accuracy: 1)
        XCTAssertEqual(size.height, CGFloat(items.count * 30 + (items.count - 1) * 6), accuracy: 0.5)
        for width: CGFloat in [300, 360, 440] {
            for item in items {
                let row = NSHostingView(rootView: DashboardModelCostChip(item: item, color: .blue).frame(width: width))
                XCTAssertEqual(row.fittingSize.height, 30, accuracy: 0.5)
                XCTAssertEqual(row.fittingSize.width, width, accuracy: 0.5)
            }
        }
        if let output = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            let renderer = ImageRenderer(content: grid.environment(\.colorScheme, .dark))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("model-identity-compact-cards.png"))
        }
    }
}
