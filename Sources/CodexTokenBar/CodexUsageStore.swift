import AppKit
import Combine
import Foundation

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot = .empty
    @Published private(set) var status: String = "正在加载本地 Codex 用量..."
    @Published private(set) var isRefreshing = false
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isPreparingUsageCache = false
    @Published private(set) var dataSourceLabel: String = "查找 Codex 目录..."
    @Published private(set) var dataSourceOrigin: String = "自动"
    @Published var selectedMode: ActivityMode = .daily

    private let resolver: CodexDataSourceResolving
    private let snapshotLoader: DashboardSnapshotLoading
    private var dataSource: CodexDataSource?
    private var timer: Timer?
    private var initialPreciseTask: Task<Void, Never>?
    private var refreshInterval: TimeInterval = 300
    private var didFinishInitialLoad = false
    private var didRunPreciseScan = false

    var currentDataSource: CodexDataSource? {
        dataSource
    }

    init(
        resolver: CodexDataSourceResolving = CodexDataSourceResolver(),
        snapshotLoader: DashboardSnapshotLoading = CodexDashboardSnapshotLoader(),
        autoStart: Bool = true
    ) {
        self.resolver = resolver
        self.snapshotLoader = snapshotLoader
        dataSource = resolver.resolve()
        updateDataSourceLabels()
        if autoStart {
            refreshInitialSnapshot()
            scheduleInitialPreciseRefresh()
            scheduleTimer()
        }
    }

    func refresh() {
        refresh(includePreciseScan: true)
    }

    private func refreshInitialSnapshot() {
        refresh(includePreciseScan: false)
    }

    private func refresh(includePreciseScan: Bool) {
        let trace = RefreshPerformanceProbe.begin("usageStore.refresh", metadata: [
            "includePreciseScan": includePreciseScan ? "1" : "0",
            "alreadyRefreshing": isRefreshing ? "1" : "0"
        ])
        guard !isRefreshing else {
            trace?.end("skipped-refresh-in-flight")
            return
        }
        dataSource = resolver.resolve()
        updateDataSourceLabels()

        guard let dataSource else {
            snapshot = .empty
            status = "未找到本地 Codex 数据目录"
            isInitialLoading = false
            isPreparingUsageCache = false
            didFinishInitialLoad = true
            trace?.end("no-data-source")
            return
        }

        let isFirstLoad = !didFinishInitialLoad
        let hasExistingSnapshot = didFinishInitialLoad || hasDisplayableSnapshot(snapshot)
        let needsCacheInitialization = includePreciseScan && !UsageCacheLifecycle.isCurrentCachePrepared
        isRefreshing = true
        isPreparingUsageCache = needsCacheInitialization
        if isFirstLoad {
            isInitialLoading = true
            status = needsCacheInitialization
                ? "正在建立本地统计缓存..."
                : "正在读取本地索引..."
        } else {
            status = needsCacheInitialization
                ? "正在建立本地统计缓存..."
                : "正在增量更新 token..."
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = dataSource
                trace?.mark("task.started", metadata: [
                    "source": source.displayPath,
                    "origin": source.originLabel
                ])
                if isFirstLoad || !includePreciseScan {
                    if includePreciseScan {
                        trace?.mark("fastSnapshot.begin")
                        if let quickSnapshot = try? await self.snapshotLoader.loadFastSnapshot(dataSource: source) {
                            self.snapshot = quickSnapshot
                            self.status = needsCacheInitialization
                                ? "\(source.originLabel) · state_5.sqlite · 正在初始化本地统计缓存..."
                                : "\(source.originLabel) · state_5.sqlite · 正在增量更新 token..."
                            trace?.mark("fastSnapshot.end", metadata: [
                                "tokens": String(quickSnapshot.stats.totalTokens),
                                "threads": String(quickSnapshot.stats.totalThreads)
                            ])
                        }
                    } else {
                        trace?.mark("fastSnapshot.begin")
                        let quickSnapshot = try await self.snapshotLoader.loadFastSnapshot(dataSource: source)
                        self.snapshot = quickSnapshot
                        self.status = "\(source.originLabel) · state_5.sqlite · 准备扫描精确 token..."
                        trace?.mark("fastSnapshot.end", metadata: [
                            "tokens": String(quickSnapshot.stats.totalTokens),
                            "threads": String(quickSnapshot.stats.totalThreads)
                        ])
                    }
                }

                if includePreciseScan {
                    trace?.mark("preciseSnapshot.begin")
                    let loaded = try await self.snapshotLoader.loadSnapshot(dataSource: source)
                    self.snapshot = loaded
                    self.didRunPreciseScan = true
                    UsageCacheLifecycle.markCurrentCachePrepared()
                    self.status = "\(source.originLabel) · token_count · 更新于 \(DateFormatter.statusString(from: loaded.generatedAt))"
                    trace?.mark("preciseSnapshot.end", metadata: [
                        "tokens": String(loaded.stats.totalTokens),
                        "calls": String(loaded.stats.totalCalls),
                        "threads": String(loaded.stats.totalThreads)
                    ])
                }
                trace?.end("ok")
            } catch {
                if !hasExistingSnapshot && !self.hasDisplayableSnapshot(self.snapshot) {
                    self.snapshot = .empty
                }
                self.status = "读取失败：\(error.localizedDescription)"
                trace?.end("failed", metadata: ["error": error.localizedDescription])
            }
            self.isRefreshing = false
            self.didFinishInitialLoad = true
            self.isInitialLoading = false
            self.isPreparingUsageCache = false
        }
    }

    private func hasDisplayableSnapshot(_ snapshot: DashboardSnapshot) -> Bool {
        snapshot.stats.totalTokens > 0
            || snapshot.stats.totalThreads > 0
            || !snapshot.dailyUsage.isEmpty
            || !snapshot.recentBins.isEmpty
            || !snapshot.hourlyUsage.isEmpty
    }

    private func scheduleInitialPreciseRefresh() {
        initialPreciseTask?.cancel()
        initialPreciseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }

            while self.isRefreshing && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            guard !Task.isCancelled, !self.didRunPreciseScan else { return }
            self.refresh()
        }
    }

    func chooseDataSourceDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 数据目录"
        panel.message = "请选择包含 sessions 文件夹的 Codex Home，例如 ~/.codex。"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = dataSource?.codexHome ?? FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataSource = resolver.saveSelectedDirectory(url)
        didRunPreciseScan = false
        updateDataSourceLabels()
        refresh()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard abs(refreshInterval - interval) > 0.5 else { return }
        refreshInterval = interval
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func updateDataSourceLabels() {
        guard let dataSource else {
            dataSourceLabel = "未发现 Codex 目录"
            dataSourceOrigin = "需更改目录"
            return
        }

        dataSourceLabel = dataSource.displayPath
        dataSourceOrigin = dataSource.originLabel
    }
}

enum ActivityMode: String, CaseIterable, Identifiable {
    case daily = "每日"
    case weekly = "每周"
    case cumulative = "累计"
    case cacheHitRate = "命中率"
    case quotaRemaining = "额度"

    var id: String { rawValue }

    var isSpecial: Bool {
        self == .cacheHitRate || self == .quotaRemaining
    }
}

extension DashboardSnapshot {
    static let empty = DashboardSnapshot(
        stats: DashboardStats(
            totalTokens: 0,
            peakDayTokens: 0,
            peakThreadTokens: 0,
            currentStreakDays: 0,
            longestStreakDays: 0,
            totalCalls: 0,
            totalThreads: 0,
            mostUsedReasoning: "未知",
            skillsExplored: 0,
            totalSkillsUsed: 0
        ),
        dailyUsage: [],
        recentBins: [],
        hourlyUsage: [],
        pluginUsage: [],
        cacheUsage: .empty,
        generatedAt: Date()
    )

    static let sample: DashboardSnapshot = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<365).compactMap { offset -> DayUsage? in
            guard let date = calendar.date(byAdding: .day, value: -364 + offset, to: today) else { return nil }
            let wave = max(0, sin(Double(offset) / 18.0))
            let spike = offset > 330 ? Double((offset % 7) + 1) / 7.0 : 0
            let tokens = Int((wave * 2_000_000) + (spike * 8_000_000))
            return DayUsage(date: date, tokens: tokens, calls: tokens == 0 ? 0 : max(1, tokens / 120_000))
        }

        let bins = (0..<288).compactMap { index -> BinUsage? in
            guard let date = calendar.date(byAdding: .minute, value: -5 * (287 - index), to: Date()) else { return nil }
            let tokens = index % 36 == 0 ? 9_800_000 : Int.random(in: 20_000...900_000)
            return BinUsage(start: date, tokens: tokens, calls: max(1, tokens / 110_000))
        }
        let currentHour = calendar.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let hourlyBins = (0..<720).compactMap { index -> BinUsage? in
            guard let date = calendar.date(byAdding: .hour, value: -719 + index, to: currentHour) else { return nil }
            let dayWave = max(0, sin(Double(index) / 21.0))
            let recentLift = index > 650 ? Double(index - 650) / 70.0 : 0
            let tokens = Int(dayWave * 1_200_000 + recentLift * 2_400_000)
            return BinUsage(start: date, tokens: tokens, calls: tokens == 0 ? 0 : max(1, tokens / 115_000))
        }
        let cacheUsage = sampleCacheUsage(days: days, bins: bins, hourlyBins: hourlyBins)

        return DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: days.reduce(0) { $0 + $1.tokens },
                peakDayTokens: days.map(\.tokens).max() ?? 0,
                peakThreadTokens: 94_000_000,
                currentStreakDays: 26,
                longestStreakDays: 26,
                totalCalls: bins.reduce(0) { $0 + $1.calls },
                totalThreads: 13_040,
                mostUsedReasoning: "中 · 51%",
                skillsExplored: 11,
                totalSkillsUsed: 31
            ),
            dailyUsage: days,
            recentBins: bins,
            hourlyUsage: hourlyBins,
            pluginUsage: [
                PluginUsage(name: "@documents", runs: 6),
                PluginUsage(name: "@spreadsheets", runs: 5),
                PluginUsage(name: "$paper-spine-translate-en", runs: 5),
                PluginUsage(name: "@presentations", runs: 3),
                PluginUsage(name: "$paper-spine", runs: 3)
            ],
            cacheUsage: cacheUsage,
            generatedAt: Date()
        )
    }()

    private static func sampleCacheUsage(days: [DayUsage], bins: [BinUsage], hourlyBins: [BinUsage]) -> TokenCacheUsage {
        func breakdown(totalTokens: Int, calls: Int, cacheRate: Double) -> TokenCacheBreakdown {
            let inputTokens = Int(Double(totalTokens) * 0.94)
            let outputTokens = max(totalTokens - inputTokens, 0)
            let cachedInputTokens = Int(Double(inputTokens) * cacheRate)
            return TokenCacheBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: Int(Double(outputTokens) * 0.28),
                totalTokens: totalTokens,
                calls: calls
            )
        }

        let daily = days
            .filter { $0.tokens > 0 }
            .map { day in
                TokenCacheBucket(
                    start: day.date,
                    breakdown: breakdown(totalTokens: day.tokens, calls: day.calls, cacheRate: 0.86)
                )
            }

        let hourly = hourlyBins
            .filter { $0.tokens > 0 }
            .map { bin in
                TokenCacheBucket(
                    start: bin.start,
                    breakdown: breakdown(totalTokens: bin.tokens, calls: bin.calls, cacheRate: 0.9)
                )
            }

        let sessions = (0..<6).map { index in
            let total = 1_800_000 + index * 420_000
            return SessionCacheUsage(
                id: "sample-\(index)",
                title: "示例会话 \(index + 1)",
                lastUpdated: Calendar.current.date(byAdding: .hour, value: -index * 3, to: Date()),
                breakdown: breakdown(totalTokens: total, calls: 4 + index, cacheRate: 0.82 + Double(index) * 0.02)
            )
        }
        var sampleTurnIndexBySession: [String: Int] = [:]
        let turns = (0..<10).compactMap { index -> TurnCacheUsage? in
            guard let timestamp = Calendar.current.date(byAdding: .minute, value: -index * 38, to: Date()) else {
                return nil
            }
            let sessionID = "sample-\(index % 6)"
            let turnIndex = (sampleTurnIndexBySession[sessionID] ?? 0) + 1
            sampleTurnIndexBySession[sessionID] = turnIndex
            let total = 260_000 + index * 42_000
            return TurnCacheUsage(
                id: "sample-turn-\(index)",
                sessionID: sessionID,
                sessionTitle: "示例会话 \((index % 6) + 1)",
                timestamp: timestamp,
                turnIndexInSession: turnIndex,
                userPrompt: "为什么今天的缓存命中率偏低？",
                assistantResponse: "我会先按会话和轮次拆开看，找到输入增长但缓存没有复用的地方。",
                breakdown: breakdown(totalTokens: total, calls: 1, cacheRate: 0.78 + Double(index % 5) * 0.04)
            )
        }

        let total = daily.reduce(TokenCacheBreakdown.empty) { partial, bucket in
            TokenCacheBreakdown(
                inputTokens: partial.inputTokens + bucket.breakdown.inputTokens,
                cachedInputTokens: partial.cachedInputTokens + bucket.breakdown.cachedInputTokens,
                outputTokens: partial.outputTokens + bucket.breakdown.outputTokens,
                reasoningOutputTokens: partial.reasoningOutputTokens + bucket.breakdown.reasoningOutputTokens,
                totalTokens: partial.totalTokens + bucket.breakdown.totalTokens,
                calls: partial.calls + bucket.breakdown.calls
            )
        }

        let recentBins = bins.map { bin in
            TokenCacheBucket(
                start: bin.start,
                breakdown: breakdown(totalTokens: bin.tokens, calls: bin.calls, cacheRate: 0.9)
            )
        }

        return TokenCacheUsage(total: total, daily: daily, hourly: hourly, recentBins: recentBins, sessions: sessions, turns: turns)
    }
}
