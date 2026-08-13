import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class TokenActivitySectionTests: XCTestCase {
    func testModeAccessibilityPresentationsAreDistinctAndStateful() {
        let presentations = ActivityMode.allCases.map { mode in
            ActivityModeOptionPresentation(mode: mode, isSelected: mode == .weekly)
        }

        XCTAssertEqual(presentations.map(\.visibleTitle), ["每日", "每周", "累计", "模型", "费用", "命中率", "额度"])
        XCTAssertEqual(
            presentations.map(\.accessibilityLabel),
            [
                "Token 活动模式 每日",
                "Token 活动模式 每周",
                "Token 活动模式 累计",
                "Token 活动模式 模型",
                "Token 活动模式 费用",
                "Token 活动模式 命中率",
                "Token 活动模式 额度",
            ]
        )
        XCTAssertEqual(
            presentations.map(\.accessibilityValue),
            ["未选择", "已选择", "未选择", "未选择", "未选择", "未选择", "未选择"]
        )
        XCTAssertEqual(Set(presentations.map(\.accessibilityLabel)).count, ActivityMode.allCases.count)
    }

    @MainActor
    func testNativeModeAccessibilityRepresentationsExposeSemanticAX() {
        for mode in ActivityMode.allCases {
            let presentation = ActivityModeOptionPresentation(
                mode: mode,
                isSelected: mode == .cacheHitRate
            )
            let button = ActivityModeAccessibilityButtonRepresentation.makeButton(
                presentation: presentation
            )

            XCTAssertEqual(button.accessibilityLabel(), "Token 活动模式 \(mode.rawValue)")
            XCTAssertEqual(
                button.accessibilityValue() as? String,
                mode == .cacheHitRate ? "已选择" : "未选择"
            )
            XCTAssertNotEqual(button.accessibilityLabel(), mode.rawValue)
            XCTAssertTrue(button.isEnabled)
        }
    }

    @MainActor
    func testHostedModeSelectorExposesSevenActionableAccessibilityButtons() throws {
        var selectedMode = ActivityMode.weekly
        let hostingView = NSHostingView(
            rootView: HostedActivityModeSelectorHarness(
                initialMode: selectedMode,
                onSelectionChange: { selectedMode = $0 }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        runMainLoopBriefly()

        let expectedLabels = ActivityMode.allCases.map { "Token 活动模式 \($0.rawValue)" }
        var buttons = hostedAccessibilityButtons(in: hostingView, labels: Set(expectedLabels))
        XCTAssertEqual(buttons.count, ActivityMode.allCases.count)
        XCTAssertEqual(buttons.compactMap { $0.accessibilityLabel() }.sorted(), expectedLabels.sorted())
        XCTAssertEqual(buttons.filter { ($0.accessibilityValue() as? String) == "已选择" }.count, 1)
        XCTAssertEqual(buttons.filter { ($0.accessibilityValue() as? String) == "未选择" }.count, 6)
        XCTAssertTrue(buttons.allSatisfy { $0.accessibilityRole() == .button })

        let dailyButton = try XCTUnwrap(
            buttons.first { $0.accessibilityLabel() == "Token 活动模式 每日" }
        )
        XCTAssertTrue(dailyButton.accessibilityPerformPress())
        runMainLoopBriefly()
        XCTAssertEqual(selectedMode, .daily)

        buttons = hostedAccessibilityButtons(in: hostingView, labels: Set(expectedLabels))
        XCTAssertEqual(
            buttons.first { $0.accessibilityLabel() == "Token 活动模式 每日" }?.accessibilityValue() as? String,
            "已选择"
        )
        XCTAssertEqual(
            buttons.first { $0.accessibilityLabel() == "Token 活动模式 每周" }?.accessibilityValue() as? String,
            "未选择"
        )
    }

    @MainActor
    func testModelHeatmapModeGroupsExactEventsByDay() throws {
        let day = Date(timeIntervalSince1970: 1_786_051_200)
        let event = TokenCacheAttributionEvent(
            id: "sol-day",
            start: day.addingTimeInterval(3600),
            model: "gpt-5.6-sol",
            breakdown: TokenCacheBreakdown(
                inputTokens: 700,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 700,
                calls: 2
            )
        )

        let prepared = TokenHeatmap.prepare(
            dailyUsage: [DayUsage(date: day, tokens: 700, calls: 2)],
            cacheDaily: [],
            attributionEvents: [event],
            quotaDaily: [],
            mode: .modelShare
        )

        let summary = try XCTUnwrap(prepared.summaries.first)
        XCTAssertTrue(summary.isModelShare)
        XCTAssertEqual(summary.modelBreakdowns.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(ModelUsagePresentation.compactText(from: summary.modelBreakdowns), "Sol 100%")
    }

    @MainActor
    func testModelCostHeatmapUsesDailyModelProjectionAndExcludesSpark() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let sol = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 500_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0,
            totalTokens: 1_100_000,
            calls: 2
        )
        let spark = TokenCacheBreakdown(
            inputTokens: 700_000,
            cachedInputTokens: 0,
            outputTokens: 50_000,
            reasoningOutputTokens: 0,
            totalTokens: 750_000,
            calls: 1
        )
        let prepared = TokenHeatmap.prepare(
            dailyUsage: [DayUsage(date: day, tokens: 1_850_000, calls: 3)],
            cacheDaily: [],
            dailyModelBreakdowns: [
                ModelTokenBucket(
                    start: day,
                    modelBreakdowns: [
                        ModelTokenBreakdown(model: "gpt-5.6-sol", breakdown: sol),
                        ModelTokenBreakdown(model: "gpt-5.3-codex-spark", breakdown: spark),
                    ]
                ),
            ],
            quotaDaily: [],
            mode: .modelCost
        )

        let summary = try XCTUnwrap(prepared.summaries.first)
        XCTAssertTrue(summary.isModelCost)
        XCTAssertEqual(try XCTUnwrap(summary.modelCostUSD), 5.75, accuracy: 0.0001)
        XCTAssertEqual(summary.modelBreakdowns.count, 2)
    }

    @MainActor
    func testModelCostHeatmapMarksActiveLegacyDayWithoutProjectionUnavailable() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let prepared = TokenHeatmap.prepare(
            dailyUsage: [DayUsage(date: day, tokens: 900, calls: 1)],
            cacheDaily: [],
            dailyModelBreakdowns: [],
            quotaDaily: [],
            mode: .modelCost
        )

        let summary = try XCTUnwrap(prepared.summaries.first)
        XCTAssertTrue(summary.isModelCost)
        XCTAssertNil(summary.modelCostUSD)
        XCTAssertTrue(summary.modelBreakdowns.isEmpty)
    }
}

private struct HostedActivityModeSelectorHarness: View {
    @State private var selectedMode: ActivityMode
    let onSelectionChange: (ActivityMode) -> Void

    init(initialMode: ActivityMode, onSelectionChange: @escaping (ActivityMode) -> Void) {
        _selectedMode = State(initialValue: initialMode)
        self.onSelectionChange = onSelectionChange
    }

    var body: some View {
        ActivityModeSelector(selectedMode: $selectedMode)
            .onChange(of: selectedMode) { _, newValue in
                onSelectionChange(newValue)
            }
    }
}

@MainActor
private func hostedAccessibilityButtons(
    in hostingView: NSHostingView<HostedActivityModeSelectorHarness>,
    labels: Set<String>
) -> [NSButton] {
    nativeButtons(in: hostingView).filter { button in
        button.accessibilityLabel().map(labels.contains) == true
    }
}

@MainActor
private func nativeButtons(in root: NSView) -> [NSButton] {
    var result: [NSButton] = []

    func visit(_ view: NSView) {
        if let button = view as? NSButton {
            result.append(button)
        }
        view.subviews.forEach(visit)
    }

    visit(root)
    return result
}

@MainActor
private func runMainLoopBriefly() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
