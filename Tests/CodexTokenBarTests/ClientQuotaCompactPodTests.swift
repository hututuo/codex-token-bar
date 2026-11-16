import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class ClientQuotaCompactPodTests: XCTestCase {
    private func item(_ client: String, _ id: String, _ label: String, _ remaining: Double? = 72.5) -> ClientQuotaItem {
        ClientQuotaItem(id: client + ":" + id, client: client, window: label,
            remaining: remaining, resetsAt: nil, source: "fixture", status: "")
    }

    func testFourAntigravityWindowsStayInTheirOwnPoolAndPeriodWhenOrderChanges() throws {
        let windows = [
            item("antigravity", "3p-weekly", "第三方模型 · 7d", 40.2),
            item("antigravity", "gemini-weekly", "Gemini · 7d", 60.4),
            item("antigravity", "3p-5h", "第三方模型 · 5h", 90.1),
            item("antigravity", "gemini-5h", "Gemini · 5h", 83.25)
        ]
        let rows = ClientQuotaPodLayout.rows(windows)
        XCTAssertEqual(rows.map(\.id), ["antigravity:gemini", "antigravity:3p"])
        XCTAssertEqual(rows[0].fiveHour?.value, "83.25%")
        XCTAssertEqual(rows[0].weekly?.value, "60.4%")
        XCTAssertEqual(rows[1].fiveHour?.value, "90.1%")
        XCTAssertEqual(rows[1].weekly?.value, "40.2%")
        XCTAssertEqual(ClientQuotaPodLayout.height(windows), 52)
    }

    func testMissingWindowKeepsAnEmptyColumnAndDoesNotBorrowFromAnotherPool() {
        let windows = [item("antigravity", "gemini-weekly", "Gemini · 7d"),
                       item("antigravity", "3p-5h", "第三方模型 · 5h")]
        let rows = ClientQuotaPodLayout.rows(windows)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].fiveHour)
        XCTAssertEqual(rows[0].weekly?.id, "antigravity:gemini-weekly")
        XCTAssertEqual(rows[1].fiveHour?.id, "antigravity:3p-5h")
        XCTAssertNil(rows[1].weekly)
    }

    func testOriginalFunctionalBarsKeepTheirHeightWhileOnlyQuotaRowsBecomeCompact() {
        let items: [QuotaSidebarItem] = [.speed, .quota("codex"), .quota("claudeDesktop"), .quota("antigravity"), .models, .tasks]
        let quotas = fixtureQuotas()
        let layout = ClientQuotaPodLayout.railLayout(items: items, quotas: quotas, availableHeight: 900)
        XCTAssertEqual(layout.barHeight, 46)
        XCTAssertEqual(layout.gap, 12)
        XCTAssertEqual(layout.height, 352)
        XCTAssertEqual(ClientQuotaPodLayout.railLayout(items: items, quotas: quotas, availableHeight: 180).height, 180)
        XCTAssertFalse(QuotaSidebarItem.radar.hasCompactRepresentation, "The original module policy is preserved")
        let hiddenQuotas = ClientQuotaPodLayout.railLayout(items: items, quotas: [], availableHeight: 900)
        XCTAssertEqual(hiddenQuotas.height, 192, "Hidden quota periods must not leave empty pods")
    }

    func testSingleWeeklyWindowAndAPIStateRemainDistinct() {
        let weekly = ClientQuotaPodLayout.rows([item("codex", "7d", "7d")])
        XCTAssertNil(weekly[0].fiveHour)
        XCTAssertNotNil(weekly[0].weekly)
        let api = ClientQuotaPodLayout.rows([item("codex", "api", "API", nil)])
        XCTAssertEqual(api[0].single?.window, "API")
        XCTAssertNil(api[0].single?.remaining)
    }

    @MainActor
    func testOriginalSidebarRendersTheSelectedQuotaPodsWithRealComponents() throws {
        let items: [QuotaSidebarItem] = [.speed, .quota("codex"), .quota("claudeDesktop"), .quota("antigravity"), .models, .tasks]
        let quotas = fixtureQuotas()
        let layout = ClientQuotaPodLayout.railLayout(items: items, quotas: quotas, availableHeight: 900)
        let root = QuotaSidebarCompactBars(items: items, quotas: quotas, layout: layout,
            rateFraction: 0.6, taskSummary: RunningThreadSummary(main: 2, subagents: 1, updatedAt: Date(), freshness: .fresh))
            .background(Color(red: 0.035, green: 0.045, blue: 0.038))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: QuotaSidebarLayout.compactWidth, height: layout.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(host.frame.width, 20)
        let colored = (0..<bitmap.pixelsWide).reduce(0) { count, x in
            count + (0..<bitmap.pixelsHigh).filter { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return max(color.redComponent, color.greenComponent, color.blueComponent) -
                    min(color.redComponent, color.greenComponent, color.blueComponent) > 0.2
            }.count
        }
        XCTAssertGreaterThan(colored, 100)
        if let directory = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("original-sidebar-with-quota-pods.png"))
        }
    }

    private func fixtureQuotas() -> [ClientQuotaItem] {
        ["codex", "claudeDesktop"].flatMap { client in
            [item(client, "5h", "5h", 78.5), item(client, "7d", "7d", 51.25)]
        } + ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"].enumerated().map { index, id in
            item("antigravity", id, id, [94.24, 84.86, 100, 100][index])
        }
    }
}
