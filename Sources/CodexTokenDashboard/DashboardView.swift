import AppKit
import SwiftUI

struct DashboardView: View {
    @StateObject private var store = CodexUsageStore()
    @StateObject private var liveMonitor = LiveRateMonitor()
    @StateObject private var floatingPanel = FloatingTokenPanelController()
    @StateObject private var statusBarPanel = StatusBarTokenController()
    @AppStorage("tokenDisplayMode") private var tokenDisplayModeRaw = TokenDisplayMode.floating.rawValue
    @AppStorage("preciseTokenCountingEnabled") private var preciseTokenCountingEnabled = false

    private var tokenDisplayMode: Binding<TokenDisplayMode> {
        Binding {
            TokenDisplayMode(rawValue: tokenDisplayModeRaw) ?? .off
        } set: { mode in
            tokenDisplayModeRaw = mode.rawValue
        }
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    HeaderView(
                        snapshot: store.snapshot,
                        status: store.status,
                        dataSourceLabel: store.dataSourceLabel,
                        dataSourceOrigin: store.dataSourceOrigin,
                        isRefreshing: store.isRefreshing,
                        onRefresh: store.refresh,
                        onChangeDirectory: store.chooseDataSourceDirectory
                    )

                    StatStrip(stats: store.snapshot.stats)

                    LiveRateView(
                        monitor: liveMonitor,
                        tokenDisplayMode: tokenDisplayMode,
                        preciseTokenCountingEnabled: $preciseTokenCountingEnabled
                    )

                    ActivitySection(
                        dailyUsage: store.snapshot.dailyUsage,
                        selectedMode: $store.selectedMode
                    )

                    RecentUsageChart(bins: store.snapshot.recentBins)
                }
                .padding(.horizontal, 54)
                .padding(.vertical, 28)
            }
        }
        .onAppear {
            liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
            updateTokenDisplaySurface()
            updateUsageRefreshCadence()
        }
        .onChange(of: tokenDisplayModeRaw) {
            updateTokenDisplaySurface()
            updateUsageRefreshCadence()
        }
        .onChange(of: preciseTokenCountingEnabled) {
            liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            updateUsageRefreshCadence()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Button {
                    Exporter.exportCSV(snapshot: store.snapshot)
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }

                Button {
                    Exporter.exportPNG(snapshot: store.snapshot)
                } label: {
                    Label("Export PNG", systemImage: "photo")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func updateTokenDisplaySurface() {
        switch TokenDisplayMode(rawValue: tokenDisplayModeRaw) ?? .off {
        case .off:
            floatingPanel.close()
            statusBarPanel.close()
        case .floating:
            statusBarPanel.close()
            floatingPanel.show(store: store, monitor: liveMonitor) {
                tokenDisplayModeRaw = TokenDisplayMode.off.rawValue
            }
        case .statusBar:
            floatingPanel.close()
            statusBarPanel.show(store: store, monitor: liveMonitor) {
                tokenDisplayModeRaw = TokenDisplayMode.off.rawValue
            }
        }
    }

    private func updateUsageRefreshCadence() {
        let displayMode = TokenDisplayMode(rawValue: tokenDisplayModeRaw) ?? .off
        let onlyCompactSurfaceVisible = displayMode != .off && !hasVisibleDashboardWindow()
        store.setRefreshInterval(onlyCompactSurfaceVisible ? 180 : 60)
    }

    private func hasVisibleDashboardWindow() -> Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
                && !(window is NSPanel)
                && window.contentViewController != nil
        }
    }
}

struct HeaderView: View {
    let snapshot: DashboardSnapshot
    let status: String
    let dataSourceLabel: String
    let dataSourceOrigin: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onChangeDirectory: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 84, height: 84)
                Text("CX")
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 7) {
                Text("Codex Token Dashboard")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.primary)

                HStack(spacing: 10) {
                    Text("@local-codex")
                        .foregroundStyle(.secondary)
                    Text("Local")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(AppTheme.borderStrong, lineWidth: 1)
                        )
                    DataSourceBadge(path: dataSourceLabel, origin: dataSourceOrigin)
                    Text(status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: onRefresh) {
                        Label(isRefreshing ? "刷新中" : "立即刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)

                    Button(action: onChangeDirectory) {
                        Label("更改目录", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                .font(.system(size: 15))
            }
        }
    }
}

struct DataSourceBadge: View {
    let path: String
    let origin: String

    var body: some View {
        Label {
            HStack(spacing: 5) {
                Text(origin)
                    .foregroundStyle(.secondary)
                Text(path)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(AppTheme.raisedBackground)
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(maxWidth: 260)
        .help(path)
    }
}

struct StatStrip: View {
    let stats: DashboardStats

    var body: some View {
        HStack(spacing: 0) {
            StatCell(value: stats.totalTokens.abbreviatedTokens, label: "累计 Token 数")
            Divider().frame(height: 46)
            StatCell(value: stats.peakDayTokens.abbreviatedTokens, label: "峰值 Token 数")
            Divider().frame(height: 46)
            StatCell(value: duration(stats.longestTaskSeconds), label: "最长任务时长")
            Divider().frame(height: 46)
            StatCell(value: "\(stats.currentStreakDays) 天", label: "当前连续天数")
            Divider().frame(height: 46)
            StatCell(value: "\(stats.longestStreakDays) 天", label: "最长连续天数")
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 18, y: 10)
        .frame(maxWidth: 980)
    }

    private func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分"
    }
}

struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ActivitySection: View {
    let dailyUsage: [DayUsage]
    @Binding var selectedMode: ActivityMode

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Token 活动")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Picker("Mode", selection: $selectedMode) {
                    ForEach(ActivityMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            TokenHeatmap(dailyUsage: dailyUsage, mode: selectedMode)
        }
        .frame(maxWidth: 980)
    }
}

struct TokenHeatmap: View {
    let dailyUsage: [DayUsage]
    let mode: ActivityMode
    @State private var hoveredIndex: Int?

    private let rows = 7
    private let cellSize: CGFloat = 12
    private let gap: CGFloat = 4

    var body: some View {
        VStack(spacing: 10) {
            let summaries = makeSummaries()
            let maxTokens = max(summaries.map(\.tokens).max() ?? 1, 1)
            let columns = makeColumnIndices()
            let selectedIndex = hoveredIndex ?? summaries.indices.last
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(columns.indices, id: \.self) { columnIndex in
                        VStack(spacing: gap) {
                            ForEach(0..<rows, id: \.self) { rowIndex in
                                if let dayIndex = columns[columnIndex][safe: rowIndex],
                                   let summary = summaries[safe: dayIndex] {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(color(for: summary, maxTokens: maxTokens))
                                        .frame(width: cellSize, height: cellSize)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(selectedIndex == dayIndex ? AppTheme.accentBlue : Color.clear, lineWidth: 1.4)
                                        )
                                        .help(tooltip(for: summary))
                                } else {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.clear)
                                        .frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                }

                HoverTrackingArea(
                    onMove: { location in
                        hoveredIndex = nearestDayIndex(at: location, columnCount: columns.count)
                    },
                    onExit: {
                        hoveredIndex = nil
                    }
                )
                .frame(width: gridWidth(columnCount: columns.count), height: gridHeight)
            }
            .frame(width: gridWidth(columnCount: columns.count), height: gridHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)

            MonthLabels(dailyUsage: dailyUsage, cellSize: cellSize, gap: gap)
            HeatmapHoverInfo(summary: hoveredIndex.flatMap { summaries[safe: $0] } ?? summaries.last)
        }
    }

    private func makeColumnIndices() -> [[Int]] {
        stride(from: 0, to: dailyUsage.count, by: rows).map { start in
            Array(start..<min(start + rows, dailyUsage.count))
        }
    }

    private var pitch: CGFloat {
        cellSize + gap
    }

    private var gridHeight: CGFloat {
        CGFloat(rows) * cellSize + CGFloat(rows - 1) * gap
    }

    private func gridWidth(columnCount: Int) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        return CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * gap
    }

    private func nearestDayIndex(at location: CGPoint, columnCount: Int) -> Int? {
        guard !dailyUsage.isEmpty, columnCount > 0 else { return nil }
        let rawColumn = Int(((location.x - cellSize / 2) / pitch).rounded())
        let rawRow = Int(((location.y - cellSize / 2) / pitch).rounded())
        let column = min(max(rawColumn, 0), columnCount - 1)
        let row = min(max(rawRow, 0), rows - 1)
        let center = CGPoint(
            x: CGFloat(column) * pitch + cellSize / 2,
            y: CGFloat(row) * pitch + cellSize / 2
        )
        let distance = hypot(location.x - center.x, location.y - center.y)
        guard distance <= cellSize else { return nil }

        let dayIndex = column * rows + row
        guard dayIndex < dailyUsage.count else { return nil }
        return dayIndex
    }

    private func color(for summary: HeatmapUsageSummary, maxTokens: Int) -> Color {
        let value = summary.tokens
        guard value > 0 else { return AppTheme.emptyCell }
        let ratio = min(1.0, Double(value) / Double(max(maxTokens, 1)))
        switch ratio {
        case 0..<0.18:
            return Color(red: 0.105, green: 0.180, blue: 0.260)
        case 0.18..<0.38:
            return Color(red: 0.120, green: 0.280, blue: 0.430)
        case 0.38..<0.62:
            return Color(red: 0.130, green: 0.400, blue: 0.660)
        case 0.62..<0.82:
            return Color(red: 0.110, green: 0.520, blue: 0.850)
        default:
            return Color(red: 0.180, green: 0.680, blue: 1.000)
        }
    }

    private func makeSummaries() -> [HeatmapUsageSummary] {
        switch mode {
        case .daily:
            return dailyUsage.map { day in
                HeatmapUsageSummary(
                    title: DateFormatter.fullDay.string(from: day.date),
                    tokens: day.tokens,
                    calls: day.calls,
                    iconName: "calendar"
                )
            }
        case .weekly:
            return weeklySummaries()
        case .cumulative:
            var runningTokens = 0
            var runningCalls = 0
            return dailyUsage.map { day in
                runningTokens += day.tokens
                runningCalls += day.calls
                return HeatmapUsageSummary(
                    title: "截至 \(DateFormatter.fullDay.string(from: day.date))",
                    tokens: runningTokens,
                    calls: runningCalls,
                    iconName: "sum"
                )
            }
        }
    }

    private func weeklySummaries() -> [HeatmapUsageSummary] {
        let calendar = Calendar.current
        var weekTotals: [String: (tokens: Int, calls: Int, first: Date, last: Date)] = [:]

        for day in dailyUsage {
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            if let current = weekTotals[key] {
                weekTotals[key] = (
                    current.tokens + day.tokens,
                    current.calls + day.calls,
                    min(current.first, day.date),
                    max(current.last, day.date)
                )
            } else {
                weekTotals[key] = (day.tokens, day.calls, day.date, day.date)
            }
        }

        return dailyUsage.map { day in
            let key = "\(calendar.component(.yearForWeekOfYear, from: day.date))-\(calendar.component(.weekOfYear, from: day.date))"
            let total = weekTotals[key] ?? (day.tokens, day.calls, day.date, day.date)
            return HeatmapUsageSummary(
                title: "\(DateFormatter.monthDay.string(from: total.first)) - \(DateFormatter.monthDay.string(from: total.last))",
                tokens: total.tokens,
                calls: total.calls,
                iconName: "calendar.badge.clock"
            )
        }
    }

    private func tooltip(for summary: HeatmapUsageSummary) -> String {
        return "\(summary.title) · \(summary.tokens.abbreviatedTokens) tokens · \(summary.calls) calls · avg \(summary.average.abbreviatedTokens)"
    }
}

struct HeatmapUsageSummary {
    let title: String
    let tokens: Int
    let calls: Int
    let iconName: String

    var average: Int {
        calls > 0 ? tokens / calls : 0
    }
}

struct HeatmapHoverInfo: View {
    let summary: HeatmapUsageSummary?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: summary == nil ? "cursorarrow.rays" : summary?.iconName ?? "calendar")
                .foregroundStyle(summary == nil ? Color.secondary : AppTheme.accentBlue)
            if let summary {
                Text(summary.title)
                    .font(.system(size: 13, weight: .medium))
                Text("\(summary.tokens.abbreviatedTokens) tokens")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
                Text("\(summary.calls) calls")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("avg \(summary.average.abbreviatedTokens)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover a day to inspect token usage")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
    }
}

struct MonthLabels: View {
    let dailyUsage: [DayUsage]
    let cellSize: CGFloat
    let gap: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(monthMarkers(), id: \.label) { marker in
                Text(marker.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: marker.width, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthMarkers() -> [(label: String, width: CGFloat)] {
        guard !dailyUsage.isEmpty else { return [] }
        var markers: [(String, CGFloat)] = []
        var previousMonth = -1
        let calendar = Calendar.current
        for (index, day) in dailyUsage.enumerated() {
            let month = calendar.component(.month, from: day.date)
            if month != previousMonth {
                previousMonth = month
                let column = index / 7
                let label = "\(month)月"
                let nextColumn = nextMonthColumn(after: index) ?? 53
                let width = CGFloat(max(2, nextColumn - column)) * (cellSize + gap)
                markers.append((label, width))
            }
        }
        return markers
    }

    private func nextMonthColumn(after index: Int) -> Int? {
        guard index < dailyUsage.count else { return nil }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: dailyUsage[index].date)
        for next in (index + 1)..<dailyUsage.count {
            let nextMonth = calendar.component(.month, from: dailyUsage[next].date)
            if nextMonth != month {
                return next / 7
            }
        }
        return nil
    }
}

struct RecentUsageChart: View {
    let bins: [BinUsage]
    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近 24 小时")
                        .font(.system(size: 19, weight: .semibold))
                    Text("30 分钟粒度 · 每分钟自动刷新")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 14) {
                    ChartLegend(color: .blue, label: "Token", value: bins.reduce(0) { $0 + $1.tokens }.abbreviatedTokens)
                    ChartLegend(color: .orange, label: "调用", value: "\(bins.reduce(0) { $0 + $1.calls })")
                }
            }

            GeometryReader { proxy in
                let maxTokens = max(bins.map(\.tokens).max() ?? 1, 1)
                let maxCalls = max(bins.map(\.calls).max() ?? 1, 1)
                let plot = CGRect(x: 0, y: 18, width: proxy.size.width, height: proxy.size.height - 42)
                let step = plot.width / CGFloat(max(bins.count - 1, 1))
                let activeIndex = hoveredIndex.flatMap { bins.indices.contains($0) ? $0 : nil } ?? bins.indices.last

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accentBlue.opacity(0.10), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)

                    ForEach(0..<4, id: \.self) { line in
                        let y = plot.minY + CGFloat(line) * plot.height / 3
                        Path { path in
                            path.move(to: CGPoint(x: plot.minX, y: y))
                            path.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                        .stroke(AppTheme.grid, style: StrokeStyle(lineWidth: 1, dash: [4, 8]))
                    }

                    tokenAreaPath(plot: plot, step: step, maxTokens: maxTokens)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accentBlue.opacity(0.22), AppTheme.accentBlue.opacity(0.055), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    tokenLinePath(plot: plot, step: step, maxTokens: maxTokens)
                        .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                        .shadow(color: AppTheme.accentBlue.opacity(0.18), radius: 5, y: 4)

                    callLinePath(plot: plot, step: step, maxCalls: maxCalls)
                        .stroke(AppTheme.accentOrange, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                    if let activeIndex {
                        let tokenPoint = tokenPoint(for: activeIndex, in: plot, step: step, maxTokens: maxTokens)
                        let callPoint = callPoint(for: activeIndex, in: plot, step: step, maxCalls: maxCalls)

                        Path { path in
                            path.move(to: CGPoint(x: tokenPoint.x, y: plot.minY))
                            path.addLine(to: CGPoint(x: tokenPoint.x, y: plot.maxY))
                        }
                        .stroke(AppTheme.accentBlue.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                        Circle()
                            .fill(AppTheme.pageBackground)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(AppTheme.accentBlue, lineWidth: 3))
                            .position(tokenPoint)

                        Circle()
                            .fill(AppTheme.pageBackground)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(AppTheme.accentOrange, lineWidth: 2.4))
                            .position(callPoint)

                        ChartHoverBubble(bin: bins[activeIndex], isHovering: hoveredIndex != nil)
                            .position(
                                x: min(max(tokenPoint.x + 88, 94), plot.maxX - 94),
                                y: max(plot.minY + 38, tokenPoint.y - 34)
                            )
                    }

                    HoverTrackingArea(
                        onMove: { location in
                            let plotLocation = CGPoint(
                                x: location.x + plot.minX,
                                y: location.y + plot.minY
                            )
                            hoveredIndex = hoverIndex(at: plotLocation, in: plot, step: step)
                        },
                        onExit: {
                            hoveredIndex = nil
                        }
                    )
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)

                    ChartTimeMarkers(bins: bins, plot: plot)
                }
            }
            .frame(height: 185)
        }
        .frame(maxWidth: 980)
    }

    private func tokenPoint(for index: Int, in plot: CGRect, step: CGFloat, maxTokens: Int) -> CGPoint {
        let x = plot.minX + CGFloat(index) * step
        let y = plot.maxY - CGFloat(bins[index].tokens) / CGFloat(maxTokens) * plot.height
        return CGPoint(x: x, y: y)
    }

    private func callPoint(for index: Int, in plot: CGRect, step: CGFloat, maxCalls: Int) -> CGPoint {
        let x = plot.minX + CGFloat(index) * step
        let y = plot.maxY - CGFloat(bins[index].calls) / CGFloat(maxCalls) * plot.height
        return CGPoint(x: x, y: y)
    }

    private func tokenLinePath(plot: CGRect, step: CGFloat, maxTokens: Int) -> Path {
        Path { path in
            for index in bins.indices {
                let point = tokenPoint(for: index, in: plot, step: step, maxTokens: maxTokens)
                index == bins.startIndex ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }

    private func callLinePath(plot: CGRect, step: CGFloat, maxCalls: Int) -> Path {
        Path { path in
            for index in bins.indices {
                let point = callPoint(for: index, in: plot, step: step, maxCalls: maxCalls)
                index == bins.startIndex ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }

    private func tokenAreaPath(plot: CGRect, step: CGFloat, maxTokens: Int) -> Path {
        var path = tokenLinePath(plot: plot, step: step, maxTokens: maxTokens)
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func hoverIndex(at location: CGPoint, in plot: CGRect, step: CGFloat) -> Int? {
        guard plot.contains(location), !bins.isEmpty else { return nil }
        let rawIndex = Int(round((location.x - plot.minX) / max(step, 1)))
        return min(max(rawIndex, bins.startIndex), bins.index(before: bins.endIndex))
    }
}

struct ChartLegend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 12))
    }
}

struct ChartHoverBubble: View {
    let bin: BinUsage
    let isHovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(isHovering ? "当前点" : "最新点")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering ? AppTheme.accentBlue : .secondary)
                Text(timeRange)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(bin.tokens.abbreviatedTokens)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
            Text("请求 \(bin.calls) 次 · avg \(average.abbreviatedTokens)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppTheme.hoverBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 12, y: 7)
    }

    private var average: Int {
        bin.calls > 0 ? bin.tokens / bin.calls : 0
    }

    private var timeRange: String {
        let end = bin.start.addingTimeInterval(30 * 60)
        return "\(DateFormatter.hourMinute.string(from: bin.start)) - \(DateFormatter.hourMinute.string(from: end))"
    }
}

struct ChartTimeMarkers: View {
    let bins: [BinUsage]
    let plot: CGRect

    var body: some View {
        ForEach(markerIndices, id: \.self) { index in
            Text(DateFormatter.hourMinute.string(from: bins[index].start))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .position(x: xPosition(for: index), y: plot.maxY + 20)
        }
    }

    private var markerIndices: [Int] {
        guard bins.count > 1 else { return [] }
        let last = bins.count - 1
        return [0, 12, 24, 36, last].filter { $0 <= last }
    }

    private func xPosition(for index: Int) -> CGFloat {
        plot.minX + CGFloat(index) * plot.width / CGFloat(max(bins.count - 1, 1))
    }
}

struct HoverTrackingArea: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
        nsView.onExit = onExit
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?

        override var isFlipped: Bool {
            true
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension DateFormatter {
    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let fullDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension NumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
