import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class ChartBubbleLayoutRenderingTests: XCTestCase {
    @MainActor func testActualMultiClientCardRendersCacheRowsWithoutPlotOverlap() throws {
        let models: [ChartModelUsage] = [
            ("codex", "gpt-6-astra", 100, 60, true),
            ("claudeCode", "claude-sonnet-4-6", 120, 100, true),
            ("gemini", "gemini-4-argon", 60, 0, false)
        ].map { client, model, input, cached, complete in
            .init(client: client, model: model, sourceModels: [model],
                breakdown: .init(inputTokens: input, cachedInputTokens: cached, outputTokens: 20,
                    reasoningOutputTokens: 0, totalTokens: input + 20, calls: 1),
                cacheReadComplete: complete, cacheWriteTokens: nil, knownCostUSD: nil, unpricedRequests: 1)
        }
        let usage = ChartUsageSummary(breakdown: models.map(\.breakdown).combined, models: models,
            cacheReadComplete: false, modelComplete: true, knownCostUSD: 0, hasKnownCost: false, unpricedRequests: 3)
        let plot = CGRect(x: 0, y: 27, width: 400, height: 215)
        let root = ZStack(alignment: .topLeading) {
            Color.blue.opacity(0.15).frame(width: plot.width, height: plot.height).offset(y: 380 + plot.minY)
            ChartHoverBubble(bin: .init(start: Date(timeIntervalSince1970: 1800014400), tokens: 340, calls: 3),
                cacheBreakdown: nil, fiveHourRemaining: nil, sevenDayRemaining: nil, bucketInterval: 300,
                isHovering: true, usage: usage)
                .chartBubblePlacement(tokenX: 200, plot: plot).offset(y: 380)
        }.frame(width: 400, height: 650, alignment: .topLeading).background(.black)
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 650)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let output = ProcessInfo.processInfo.environment["TOKENBAR_POLISH_RENDER_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("bubble-multi-client-cache.png"))
        }
    }

    /// Offscreen unit fixture, with no NSWindow or installed-app interaction.
    @MainActor func testFirstRenderedFrameKeepsShortAndTallCardsAboveThePlot() throws {
        for height: CGFloat in [90, 340, 480] {
            let plot = CGRect(x: 0, y: 27, width: 400, height: 215)
            let root = ZStack(alignment: .topLeading) {
                Color(red: 0, green: 0, blue: 1).frame(width: plot.width, height: plot.height).offset(y: 600 + plot.minY)
                Color(red: 1, green: 0, blue: 0).frame(width: 240, height: height)
                    .chartBubblePlacement(tokenX: 200, plot: plot).offset(y: 600)
            }.frame(width: 400, height: 900, alignment: .topLeading).background(.black)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(x: 0, y: 0, width: 400, height: 900)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["TOKENBAR_POLISH_RENDER_OUTPUT"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("bubble-height-\(Int(height)).png"))
            }
            let scale = CGFloat(bitmap.pixelsHigh) / 900
            var redRows: [Int] = [], blueRows: [Int] = []
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8 && color.blueComponent < 0.2 { redRows.append(y) }
                if color.blueComponent > 0.8 && color.redComponent < 0.2 { blueRows.append(y) }
            }
            let redEnd = try XCTUnwrap(redRows.last), blueStart = try XCTUnwrap(blueRows.first)
            XCTAssertEqual(CGFloat(blueStart - redEnd - 1) / scale, recentChartHoverBubblePlotClearance, accuracy: 1)
            XCTAssertEqual(CGFloat(redRows.count) / scale, height, accuracy: 1)
        }
    }
}
