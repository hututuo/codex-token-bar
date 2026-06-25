import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class CodexUsageStoreTests: XCTestCase {
    func testVisibleDashboardRefreshesFasterThanCompactOnlySurfaces() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)

        XCTAssertTrue(source.contains("onlyCompactSurfaceVisible ? 300 : 180"))
    }

    func testDashboardRefreshReloadsQuotaHistoryTimeline() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardView = projectRoot.appendingPathComponent("Sources/CodexTokenBar/DashboardView.swift")
        let source = try String(contentsOf: dashboardView, encoding: .utf8)
        let refreshBlock = try XCTUnwrap(sourceBlock(named: "refreshAllData", in: source, endingBefore: "private var requestedInterfaceScale"))

        XCTAssertTrue(refreshBlock.contains("quotaHistoryStore.reload()"))
        XCTAssertTrue(source.contains("NSWorkspace.didWakeNotification"))
    }

    func testInitialPreciseFailurePreservesFastUsageSnapshot() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/.codex"),
            origin: .defaultHome
        )
        let fastSnapshot = makeSnapshot(totalTokens: 88_000, dayTokens: 0)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(fastSnapshot)],
            preciseResults: [.failure(UsageStoreTestError())]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("initial precise failure") {
            store.status.hasPrefix("读取失败") && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 88_000)
        XCTAssertEqual(store.snapshot.stats.totalThreads, 2)
        XCTAssertFalse(store.isInitialLoading)
    }

    func testRefreshFailurePreservesLastSuccessfulUsageSnapshot() async {
        let source = CodexDataSource(
            codexHome: URL(fileURLWithPath: "/tmp/codex-token-bar-tests/.codex"),
            origin: .defaultHome
        )
        let successfulSnapshot = makeSnapshot(totalTokens: 12_345, dayTokens: 678)
        let loader = SequentialDashboardSnapshotLoader(
            fastResults: [.success(.empty)],
            preciseResults: [
                .success(successfulSnapshot),
                .failure(UsageStoreTestError())
            ]
        )
        let store = CodexUsageStore(
            resolver: StaticCodexDataSourceResolver(source: source),
            snapshotLoader: loader,
            autoStart: false
        )

        store.refresh()
        await waitUntil("successful usage refresh") {
            store.snapshot.stats.totalTokens == 12_345 && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 12_345)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 678)

        store.refresh()
        await waitUntil("failed usage refresh") {
            store.status.hasPrefix("读取失败") && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot.stats.totalTokens, 12_345)
        XCTAssertEqual(store.snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 678)
        XCTAssertFalse(store.snapshot.dailyUsage.isEmpty)
    }

    private func makeSnapshot(totalTokens: Int, dayTokens: Int) -> DashboardSnapshot {
        let now = Date(timeIntervalSince1970: 1_800)
        return DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: totalTokens,
                peakDayTokens: dayTokens,
                peakThreadTokens: 999,
                currentStreakDays: 1,
                longestStreakDays: 1,
                totalCalls: 3,
                totalThreads: 2,
                mostUsedReasoning: "中",
                skillsExplored: 0,
                totalSkillsUsed: 0
            ),
            dailyUsage: [DayUsage(date: now, tokens: dayTokens, calls: 3)],
            recentBins: [BinUsage(start: now, tokens: dayTokens, calls: 3)],
            hourlyUsage: [BinUsage(start: now, tokens: dayTokens, calls: 3)],
            pluginUsage: [],
            cacheUsage: .empty,
            generatedAt: now
        )
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private func sourceBlock(named name: String, in source: String, endingBefore marker: String) -> String? {
    guard let start = source.range(of: "private func \(name)")?.lowerBound,
          let end = source[start...].range(of: marker)?.lowerBound else {
        return nil
    }
    return String(source[start..<end])
}

private final class StaticCodexDataSourceResolver: CodexDataSourceResolving {
    private let source: CodexDataSource?

    init(source: CodexDataSource?) {
        self.source = source
    }

    func resolve() -> CodexDataSource? {
        source
    }

    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? {
        source
    }
}

private actor SequentialDashboardSnapshotLoader: DashboardSnapshotLoading {
    private var fastResults: [Result<DashboardSnapshot, Error>]
    private var preciseResults: [Result<DashboardSnapshot, Error>]

    init(
        fastResults: [Result<DashboardSnapshot, Error>],
        preciseResults: [Result<DashboardSnapshot, Error>]
    ) {
        self.fastResults = fastResults
        self.preciseResults = preciseResults
    }

    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try next(from: &fastResults)
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try next(from: &preciseResults)
    }

    private func next(from results: inout [Result<DashboardSnapshot, Error>]) throws -> DashboardSnapshot {
        guard !results.isEmpty else {
            throw UsageStoreTestError()
        }
        return try results.removeFirst().get()
    }
}

private struct UsageStoreTestError: LocalizedError {
    var errorDescription: String? {
        "模拟用量读取失败"
    }
}
