import AppKit
import Combine
import Foundation

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot = .empty
    @Published private(set) var status: String = "Loading local Codex usage..."
    @Published private(set) var isRefreshing = false
    @Published private(set) var dataSourceLabel: String = "查找 Codex 目录..."
    @Published private(set) var dataSourceOrigin: String = "自动"
    @Published var selectedMode: ActivityMode = .daily

    private let resolver = CodexDataSourceResolver()
    private var dataSource: CodexDataSource?
    private var timer: Timer?
    private var refreshInterval: TimeInterval = 60

    init() {
        dataSource = resolver.resolve()
        updateDataSourceLabels()
        refresh()
        scheduleTimer()
    }

    func refresh() {
        guard !isRefreshing else { return }
        dataSource = resolver.resolve()
        updateDataSourceLabels()

        guard let dataSource else {
            snapshot = .empty
            status = "未找到本地 Codex 数据目录"
            return
        }

        isRefreshing = true
        status = "Scanning \(dataSource.displayPath)/sessions..."

        Task {
            do {
                let source = dataSource
                let loaded = try await Task.detached(priority: .utility) {
                    try CodexUsageAnalyzer(dataSource: source).load()
                }.value
                snapshot = loaded
                status = "\(source.originLabel) · token_count · Updated \(DateFormatter.status.string(from: loaded.generatedAt))"
            } catch {
                snapshot = .empty
                status = "读取失败：\(error.localizedDescription)"
            }
            isRefreshing = false
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

    var id: String { rawValue }
}

extension DashboardSnapshot {
    static let empty = DashboardSnapshot(
        stats: DashboardStats(
            totalTokens: 0,
            peakDayTokens: 0,
            longestTaskSeconds: 0,
            currentStreakDays: 0,
            longestStreakDays: 0,
            totalCalls: 0,
            totalThreads: 0,
            fastModePercent: 0,
            mostUsedReasoning: "未知",
            skillsExplored: 0,
            totalSkillsUsed: 0
        ),
        dailyUsage: [],
        recentBins: [],
        pluginUsage: [],
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

        let bins = (0..<48).compactMap { index -> BinUsage? in
            guard let date = calendar.date(byAdding: .minute, value: -30 * (47 - index), to: Date()) else { return nil }
            let tokens = index % 6 == 0 ? 9_800_000 : Int.random(in: 120_000...4_500_000)
            return BinUsage(start: date, tokens: tokens, calls: max(1, tokens / 110_000))
        }

        return DashboardSnapshot(
            stats: DashboardStats(
                totalTokens: days.reduce(0) { $0 + $1.tokens },
                peakDayTokens: days.map(\.tokens).max() ?? 0,
                longestTaskSeconds: 94 * 60,
                currentStreakDays: 26,
                longestStreakDays: 26,
                totalCalls: bins.reduce(0) { $0 + $1.calls },
                totalThreads: 13_040,
                fastModePercent: 14,
                mostUsedReasoning: "中 · 51%",
                skillsExplored: 11,
                totalSkillsUsed: 31
            ),
            dailyUsage: days,
            recentBins: bins,
            pluginUsage: [
                PluginUsage(name: "@documents", runs: 6),
                PluginUsage(name: "@spreadsheets", runs: 5),
                PluginUsage(name: "$paper-spine-translate-en", runs: 5),
                PluginUsage(name: "@presentations", runs: 3),
                PluginUsage(name: "$paper-spine", runs: 3)
            ],
            generatedAt: Date()
        )
    }()
}

extension DateFormatter {
    static let status: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
