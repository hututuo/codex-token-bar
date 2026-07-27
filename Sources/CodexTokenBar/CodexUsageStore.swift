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
    @Published private(set) var dataSourceIdentity: String?
    @Published private(set) var dataSourceBindingKey = "none"
    @Published var selectedMode: ActivityMode = .daily

    private let resolver: CodexDataSourceResolving
    private let snapshotLoader: DashboardSnapshotLoading
    private var dataSource: CodexDataSource?
    private var timer: Timer?
    private var initialPreciseTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private(set) var sourceIdentityGeneration = 0
    private(set) var sourceBindingGeneration = 0
    private var activeRefreshSourceID: String?
    private var snapshotSourceID: String?
    private var refreshInterval: TimeInterval = 300
    private var didFinishInitialLoad = false
    private var didRunPreciseScan = false
    private var backgroundActivityEnabled = true
    private var onlyCompactSurfaceVisible = false
    private var activeRefreshCompactOnly = false
    private var pendingFullRefresh = false

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
        dataSourceIdentity = dataSource?.stableIdentityKey
        dataSourceBindingKey = Self.bindingKey(for: dataSource)
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

    // 决策口径：仅紧凑 surface（状态栏/悬浮窗）可见时，周期刷新走轻量
    // summary（索引增量同步 + 三条 SUM SQL），不重建时间序列/排行/摘录。
    func setOnlyCompactSurfaceVisible(_ visible: Bool) {
        guard onlyCompactSurfaceVisible != visible else { return }
        onlyCompactSurfaceVisible = visible
        // 仪表盘展开时立即全量刷新一次，补齐轻量期间未更新的时间序列/排行。
        if !visible, didRunPreciseScan, backgroundActivityEnabled {
            refresh()
        }
    }

    @discardableResult
    func setDataSource(_ nextDataSource: CodexDataSource?) -> Bool {
        let previousIdentity = dataSource?.stableIdentityKey
        let nextIdentity = nextDataSource?.stableIdentityKey
        let previousPath = dataSource?.codexHome.standardizedFileURL.path
        let nextPath = nextDataSource?.codexHome.standardizedFileURL.path
        let identityChanged = previousIdentity != nextIdentity
        let bindingChanged = previousPath != nextPath
        dataSource = nextDataSource
        dataSourceIdentity = nextIdentity
        dataSourceBindingKey = Self.bindingKey(for: nextDataSource)
        updateDataSourceLabels()

        guard identityChanged || bindingChanged else { return false }

        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        sourceBindingGeneration += 1
        activeRefreshSourceID = nil
        activeRefreshCompactOnly = false
        pendingFullRefresh = false
        isRefreshing = false
        isPreparingUsageCache = false
        guard identityChanged else { return true }

        sourceIdentityGeneration += 1
        snapshot = .empty
        snapshotSourceID = nil
        didRunPreciseScan = false
        status = nextDataSource == nil
            ? "未找到本地 Codex 数据目录"
            : "正在读取新数据源..."
        return true
    }

    private static func bindingKey(for dataSource: CodexDataSource?) -> String {
        guard let dataSource else { return "none" }
        return "\(dataSource.stableIdentityKey)\u{0}\(dataSource.codexHome.standardizedFileURL.path)"
    }

    private func refreshInitialSnapshot() {
        refresh(includePreciseScan: false)
    }

    private func refresh(includePreciseScan: Bool) {
        let resolvedDataSource = resolver.resolve()
        let requestedSourceID = resolvedDataSource.map { refreshSourceID(for: $0) }
        let trace = RefreshPerformanceProbe.begin("usageStore.refresh", metadata: [
            "includePreciseScan": includePreciseScan ? "1" : "0",
            "alreadyRefreshing": isRefreshing ? "1" : "0",
            "source": resolvedDataSource?.displayPath ?? "nil"
        ])
        let requestedBindingKey = Self.bindingKey(for: resolvedDataSource)
        if isRefreshing,
           requestedSourceID == activeRefreshSourceID,
           requestedBindingKey == dataSourceBindingKey {
            if includePreciseScan,
               !onlyCompactSurfaceVisible,
               activeRefreshCompactOnly {
                pendingFullRefresh = true
            }
            trace?.end("skipped-refresh-in-flight")
            return
        }
        if requestedBindingKey != dataSourceBindingKey {
            setDataSource(resolvedDataSource)
            trace?.mark("rebound-source")
        } else if isRefreshing {
            refreshTask?.cancel()
            refreshTask = nil
            refreshGeneration += 1
            isRefreshing = false
            trace?.mark("cancelled-stale-refresh")
        }
        setDataSource(resolvedDataSource)

        guard let dataSource else {
            refreshTask?.cancel()
            refreshGeneration += 1
            activeRefreshSourceID = nil
            activeRefreshCompactOnly = false
            pendingFullRefresh = false
            snapshot = .empty
            snapshotSourceID = nil
            status = "未找到本地 Codex 数据目录"
            isInitialLoading = false
            isPreparingUsageCache = false
            didFinishInitialLoad = true
            trace?.end("no-data-source")
            return
        }

        let sourceID = refreshSourceID(for: dataSource)
        if let snapshotSourceID, snapshotSourceID != sourceID {
            snapshot = .empty
            self.snapshotSourceID = nil
        }
        let isFirstLoad = !didFinishInitialLoad
        let needsCacheInitialization = includePreciseScan && !UsageCacheLifecycle.isCurrentCachePrepared
        activeRefreshCompactOnly = includePreciseScan
            && !isFirstLoad
            && onlyCompactSurfaceVisible
            && snapshot.hasPreciseTokenUsage
            && snapshotSourceID == sourceID
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let bindingGeneration = sourceBindingGeneration
        activeRefreshSourceID = sourceID
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

        refreshTask = Task { @MainActor [weak self] in
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
                            guard self.isCurrentRefresh(
                                generation: generation,
                                bindingGeneration: bindingGeneration,
                                sourceID: sourceID
                            ) else {
                                trace?.end("stale-after-fastSnapshot")
                                return
                            }
                            self.publish(quickSnapshot, sourceID: sourceID)
                            self.status = quickSnapshot.hasPreciseTokenUsage
                                ? (needsCacheInitialization
                                    ? "\(source.originLabel) · state_5.sqlite · 正在初始化本地统计缓存..."
                                    : "\(source.originLabel) · state_5.sqlite · 正在增量更新 token...")
                                : self.metadataOnlyStatus(origin: source.originLabel)
                            trace?.mark("fastSnapshot.end", metadata: [
                                "tokens": String(quickSnapshot.stats.totalTokens),
                                "threads": String(quickSnapshot.stats.totalThreads)
                            ])
                        }
                    } else {
                        trace?.mark("fastSnapshot.begin")
                        let quickSnapshot = try await self.snapshotLoader.loadFastSnapshot(dataSource: source)
                        guard self.isCurrentRefresh(
                            generation: generation,
                            bindingGeneration: bindingGeneration,
                            sourceID: sourceID
                        ) else {
                            trace?.end("stale-after-fastSnapshot")
                            return
                        }
                        self.publish(quickSnapshot, sourceID: sourceID)
                        self.status = quickSnapshot.hasPreciseTokenUsage
                            ? "\(source.originLabel) · state_5.sqlite · 准备扫描精确 token..."
                            : self.metadataOnlyStatus(origin: source.originLabel)
                        trace?.mark("fastSnapshot.end", metadata: [
                            "tokens": String(quickSnapshot.stats.totalTokens),
                            "threads": String(quickSnapshot.stats.totalThreads)
                        ])
                    }
                }

                if includePreciseScan {
                    var compactSummaryApplied = false
                    if !isFirstLoad,
                       self.onlyCompactSurfaceVisible,
                       self.snapshot.hasPreciseTokenUsage,
                       self.snapshotSourceID == sourceID {
                        trace?.mark("compactSummary.begin")
                        // 轻量路径失败只回退全量，不让它变成整轮刷新失败。
                        let summary = try? await self.snapshotLoader.loadCompactSummary(
                            dataSource: source
                        )
                        guard self.isCurrentRefresh(
                            generation: generation,
                            bindingGeneration: bindingGeneration,
                            sourceID: sourceID
                        ) else {
                            trace?.end("stale-after-compactSummary")
                            return
                        }
                        if let summary {
                            self.publish(
                                Self.applyingCompactSummary(summary, to: self.snapshot),
                                sourceID: sourceID
                            )
                            self.didRunPreciseScan = true
                            self.status = "\(source.originLabel) · token_count · 更新于 \(DateFormatter.statusString(from: summary.generatedAt))"
                            trace?.mark("compactSummary.end", metadata: [
                                "tokens": String(summary.totalTokens)
                            ])
                            compactSummaryApplied = true
                        } else {
                            trace?.mark("compactSummary.unavailable")
                        }
                    }
                    if !compactSummaryApplied {
                        trace?.mark("preciseSnapshot.begin")
                        let loaded = try await self.snapshotLoader.loadSnapshot(dataSource: source)
                        guard self.isCurrentRefresh(
                            generation: generation,
                            bindingGeneration: bindingGeneration,
                            sourceID: sourceID
                        ) else {
                            trace?.end("stale-after-preciseSnapshot")
                            return
                        }
                        if loaded.hasPreciseTokenUsage {
                            self.publish(loaded, sourceID: sourceID)
                            self.didRunPreciseScan = true
                            UsageCacheLifecycle.markCurrentCachePrepared()
                            self.status = "\(source.originLabel) · token_count · 更新于 \(DateFormatter.statusString(from: loaded.generatedAt))"
                            trace?.mark("preciseSnapshot.end", metadata: [
                                "tokens": String(loaded.stats.totalTokens),
                                "calls": String(loaded.stats.totalCalls),
                                "threads": String(loaded.stats.totalThreads)
                            ])
                        } else {
                            if !self.snapshot.hasPreciseTokenUsage {
                                self.publish(loaded, sourceID: sourceID)
                                self.status = self.metadataOnlyStatus(origin: source.originLabel)
                            } else {
                                self.status = self.staleMetadataOnlyStatus(origin: source.originLabel)
                            }
                            trace?.mark("preciseSnapshot.metadataOnly", metadata: [
                                "threads": String(loaded.stats.totalThreads)
                            ])
                        }
                    }
                }
                trace?.end("ok")
            } catch {
                guard self.isCurrentRefresh(
                    generation: generation,
                    bindingGeneration: bindingGeneration,
                    sourceID: sourceID
                ) else {
                    trace?.end("stale-failed", metadata: ["error": error.localizedDescription])
                    return
                }
                let retainedTrustedSnapshot = self.snapshotSourceID == sourceID
                    && self.hasDisplayableSnapshot(self.snapshot)
                if !retainedTrustedSnapshot {
                    self.snapshot = .empty
                    self.snapshotSourceID = nil
                }
                self.status = retainedTrustedSnapshot
                    ? "读取失败（保留上次可信数据，当前显示已陈旧）：\(error.localizedDescription)"
                    : "读取失败：\(error.localizedDescription)"
                trace?.end("failed", metadata: ["error": error.localizedDescription])
            }
            if self.isCurrentRefresh(
                generation: generation,
                bindingGeneration: bindingGeneration,
                sourceID: sourceID
            ) {
                let shouldRunPendingFullRefresh = self.pendingFullRefresh
                    && !self.onlyCompactSurfaceVisible
                    && self.backgroundActivityEnabled
                self.pendingFullRefresh = false
                self.activeRefreshCompactOnly = false
                self.isRefreshing = false
                self.activeRefreshSourceID = nil
                self.didFinishInitialLoad = true
                self.isInitialLoading = false
                self.isPreparingUsageCache = false
                if shouldRunPendingFullRefresh {
                    self.refresh(includePreciseScan: true)
                }
            }
        }
    }

    private func isCurrentRefresh(
        generation: Int,
        bindingGeneration: Int,
        sourceID: String
    ) -> Bool {
        !Task.isCancelled
            && refreshGeneration == generation
            && sourceBindingGeneration == bindingGeneration
            && activeRefreshSourceID == sourceID
    }

    private func refreshSourceID(for dataSource: CodexDataSource) -> String {
        dataSource.stableIdentityKey
    }

    private func publish(_ snapshot: DashboardSnapshot, sourceID: String) {
        self.snapshot = snapshot
        snapshotSourceID = sourceID
    }

    // 轻量 summary 只覆盖紧凑 surface 消费的字段（累计 token、今日 token/
    // 调用数）；时间序列/排行/摘录保留上次全量构建结果，展开仪表盘时由
    // setOnlyCompactSurfaceVisible 触发的全量刷新补齐。
    static func applyingCompactSummary(
        _ summary: CodexUsageAnalyzer.CompactUsageSummary,
        to previous: DashboardSnapshot
    ) -> DashboardSnapshot {
        let calendar = Calendar.current
        var dailyUsage = previous.dailyUsage
        let todayEntry = DayUsage(
            date: calendar.startOfDay(for: summary.generatedAt),
            tokens: summary.todayTokens,
            calls: summary.todayCalls
        )
        if let index = dailyUsage.firstIndex(where: {
            calendar.isDate($0.date, inSameDayAs: summary.generatedAt)
        }) {
            dailyUsage[index] = todayEntry
        } else {
            dailyUsage.append(todayEntry)
        }
        let stats = DashboardStats(
            totalTokens: summary.totalTokens,
            peakDayTokens: max(previous.stats.peakDayTokens, summary.todayTokens),
            peakThreadTokens: previous.stats.peakThreadTokens,
            currentStreakDays: previous.stats.currentStreakDays,
            longestStreakDays: previous.stats.longestStreakDays,
            totalCalls: previous.stats.totalCalls,
            totalThreads: previous.stats.totalThreads,
            mostUsedReasoning: previous.stats.mostUsedReasoning,
            skillsExplored: previous.stats.skillsExplored,
            totalSkillsUsed: previous.stats.totalSkillsUsed,
            totalInputTokens: previous.stats.totalInputTokens,
            totalCachedInputTokens: previous.stats.totalCachedInputTokens,
            totalOutputTokens: previous.stats.totalOutputTokens,
            firstUsageAt: previous.stats.firstUsageAt
        )
        return DashboardSnapshot(
            stats: stats,
            dailyUsage: dailyUsage,
            recentBins: previous.recentBins,
            hourlyUsage: previous.hourlyUsage,
            pluginUsage: previous.pluginUsage,
            cacheUsage: previous.cacheUsage,
            usagePrecision: previous.usagePrecision,
            generatedAt: summary.generatedAt
        )
    }

    private func hasDisplayableSnapshot(_ snapshot: DashboardSnapshot) -> Bool {
        snapshot.stats.totalTokens > 0
            || snapshot.stats.totalThreads > 0
            || !snapshot.dailyUsage.isEmpty
            || !snapshot.recentBins.isEmpty
            || !snapshot.hourlyUsage.isEmpty
    }

    private func metadataOnlyStatus(origin: String) -> String {
        "\(origin) · state_5.sqlite · 仅显示会话元数据，精确 token 仍在读取..."
    }

    private func staleMetadataOnlyStatus(origin: String) -> String {
        "\(origin) · 用量已陈旧 · 当前仅元数据，保留上次可信 token"
    }

    private func scheduleInitialPreciseRefresh() {
        initialPreciseTask?.cancel()
        initialPreciseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.backgroundActivityEnabled else { return }

            while self.isRefreshing && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            guard !Task.isCancelled, self.backgroundActivityEnabled, !self.didRunPreciseScan else { return }
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
        setDataSource(resolver.saveSelectedDirectory(url))
        refresh()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard abs(refreshInterval - interval) > 0.5 else { return }
        refreshInterval = interval
        scheduleTimer()
    }

    func setBackgroundActivityEnabled(_ enabled: Bool) {
        guard backgroundActivityEnabled != enabled else { return }
        backgroundActivityEnabled = enabled
        if enabled {
            scheduleTimer()
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            initialPreciseTask?.cancel()
            initialPreciseTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            refreshGeneration += 1
            activeRefreshSourceID = nil
            activeRefreshCompactOnly = false
            pendingFullRefresh = false
            isRefreshing = false
            isPreparingUsageCache = false
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard backgroundActivityEnabled else {
            timer = nil
            return
        }
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
        usagePrecision: .metadataOnly,
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
                totalSkillsUsed: 31,
                totalInputTokens: cacheUsage.total.inputTokens,
                totalCachedInputTokens: cacheUsage.total.cachedInputTokens,
                totalOutputTokens: cacheUsage.total.outputTokens,
                firstUsageAt: days.first(where: { $0.tokens > 0 })?.date
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
