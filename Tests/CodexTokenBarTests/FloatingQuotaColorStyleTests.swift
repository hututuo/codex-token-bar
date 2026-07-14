import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class FloatingQuotaColorStyleTests: XCTestCase {
    func testModesExposeStableLabelsAndInvalidValuesFallBackToAdaptive() {
        XCTAssertEqual(FloatingQuotaColorMode.allCases.map(\.label), ["随百分比", "固定色", "面板渐变"])

        let style = FloatingQuotaColorStyle(
            modeRaw: "unknown",
            fixedHex: "invalid",
            gradientAppearance: .default
        )

        XCTAssertEqual(style.mode, .adaptive)
    }

    func testFixedColorUsesConfiguredHex() throws {
        let style = FloatingQuotaColorStyle(
            modeRaw: FloatingQuotaColorMode.fixed.rawValue,
            fixedHex: "#123456",
            gradientAppearance: .default
        )
        let color = try XCTUnwrap(NSColor(style.resolvedFixedColor).usingColorSpace(.sRGB))

        XCTAssertEqual(color.redComponent, 0x12 / 255.0, accuracy: 0.002)
        XCTAssertEqual(color.greenComponent, 0x34 / 255.0, accuracy: 0.002)
        XCTAssertEqual(color.blueComponent, 0x56 / 255.0, accuracy: 0.002)
    }

    @MainActor
    func testEveryColorModeRendersInsideTheSameQuotaSegmentFrame() {
        let appearance = FloatingPanelAppearance(
            startHex: "#102040",
            endHex: "#40A0FF",
            directionRaw: FloatingPanelGradientDirection.leadingToTrailing.rawValue,
            styleRaw: FloatingPanelGradientStyle.linear.rawValue
        )
        let window = AccountQuotaWindow(label: "7d", usedPercent: 35, resetsAt: nil)

        for mode in FloatingQuotaColorMode.allCases {
            let style = FloatingQuotaColorStyle(
                modeRaw: mode.rawValue,
                fixedHex: "#1469CC",
                gradientAppearance: appearance
            )
            let hostingView = NSHostingView(
                rootView: TokenQuotaMiniSegment(window: window)
                    .environment(\.tokenDisplayQuotaColorStyle, style)
                    .frame(width: 120, height: 16.5)
            )
            hostingView.layoutSubtreeIfNeeded()

            XCTAssertEqual(hostingView.fittingSize.width, 120, accuracy: 0.5, "mode: \(mode.rawValue)")
            XCTAssertEqual(hostingView.fittingSize.height, 16.5, accuracy: 0.5, "mode: \(mode.rawValue)")
        }
    }
}
